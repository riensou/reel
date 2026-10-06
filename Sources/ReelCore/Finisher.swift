import AVFoundation
import CoreImage
import Foundation

/// Turns a `Recording` into the final file:
/// joins pause segments, mixes system audio + mic into one AAC track (most
/// players only play the first audio track), and optionally applies per-frame
/// effects (auto-zoom, smoothed cursor). Video is passed through untouched
/// unless effects are on.
public enum Finisher {
    /// Per-frame image transform; `time` is in the final file's timeline.
    public typealias FrameEffect = @Sendable (CIImage, CMTime) -> CIImage

    public struct Job: Sendable {
        public var segments: [URL]
        public var output: URL
        public var format: VideoFormat = .mp4
        public var mergeAudio = true
        public var effect: FrameEffect?

        public init(segments: [URL], output: URL) {
            self.segments = segments
            self.output = output
        }
    }

    /// True when the single recorded segment can be used as-is.
    public static func canSkip(_ job: Job) async -> Bool {
        guard job.segments.count == 1, job.effect == nil else { return false }
        let tracks = (try? await AVURLAsset(url: job.segments[0]).loadTracks(withMediaType: .audio)) ?? []
        return tracks.count <= 1 || !job.mergeAudio
    }

    public static func run(_ job: Job, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        // 1. Join segments into one timeline. Tracks keep their order across
        //    segments (same stream config), so track i maps to composition track i.
        let composition = AVMutableComposition()
        var videoTrack: AVMutableCompositionTrack?
        var audioTracks: [AVMutableCompositionTrack] = []
        var cursor = CMTime.zero
        var transform = CGAffineTransform.identity
        for url in job.segments {
            let asset = AVURLAsset(url: url)
            guard let v = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let range = try await v.load(.timeRange)
            if videoTrack == nil {
                videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                transform = try await v.load(.preferredTransform)
            }
            try videoTrack!.insertTimeRange(range, of: v, at: cursor)
            for (i, a) in try await asset.loadTracks(withMediaType: .audio).enumerated() {
                if i >= audioTracks.count {
                    audioTracks.append(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!)
                }
                // Audio can start slightly after video; clamp into the segment's video range.
                let aRange = try await a.load(.timeRange).intersection(range)
                if aRange.duration > .zero {
                    try audioTracks[i].insertTimeRange(aRange, of: a, at: cursor + (aRange.start - range.start))
                }
            }
            cursor = cursor + range.duration
        }
        guard let videoTrack else { throw ReelError.writeFailed(job.output) }
        videoTrack.preferredTransform = transform
        let duration = cursor

        // 2. Reader.
        let reader = try AVAssetReader(asset: composition)
        let videoOut: AVAssetReaderOutput
        var videoSettings: [String: Any]?
        let formatHint = try await videoTrack.load(.formatDescriptions).first
        if let effect = job.effect {
            let vc = try await AVMutableVideoComposition.videoComposition(with: composition) { request in
                let out = effect(request.sourceImage, request.compositionTime)
                request.finish(with: out.cropped(to: request.sourceImage.extent), context: nil)
            }
            let o = AVAssetReaderVideoCompositionOutput(
                videoTracks: [videoTrack],
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            )
            o.videoComposition = vc
            videoOut = o
            let size = vc.renderSize
            let codec: AVVideoCodecType = formatHint.map { CMFormatDescriptionGetMediaSubType($0) } == kCMVideoCodecType_HEVC ? .hevc : .h264
            let fps = Double(try await videoTrack.load(.nominalFrameRate)).clamped(to: 24...60)
            videoSettings = [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    // Screen content is mostly static; ~0.1 bit/pixel/frame stays crisp.
                    AVVideoAverageBitRateKey: Int(size.width * size.height * fps * 0.1),
                    AVVideoExpectedSourceFrameRateKey: fps,
                ],
            ]
        } else {
            videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        }
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)

        var audioOuts: [(AVAssetReaderOutput, CMFormatDescription?)] = []
        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
        ]
        if job.mergeAudio, !audioTracks.isEmpty {
            let mix = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcm)
            reader.add(mix)
            audioOuts.append((mix, nil))
        } else {
            for t in audioTracks {
                let o = AVAssetReaderTrackOutput(track: t, outputSettings: nil)
                reader.add(o)
                audioOuts.append((o, try await t.load(.formatDescriptions).first))
            }
        }

        // 3. Writer.
        try? FileManager.default.removeItem(at: job.output)
        let writer = try AVAssetWriter(outputURL: job.output, fileType: job.format == .mp4 ? .mp4 : .mov)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings, sourceFormatHint: videoSettings == nil ? formatHint : nil)
        videoIn.transform = transform
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)
        var audioIns: [AVAssetWriterInput] = []
        for (_, hint) in audioOuts {
            let settings: [String: Any]? = job.mergeAudio ? [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ] : nil
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioIns.append(input)
        }

        guard reader.startReading() else { throw reader.error ?? ReelError.writeFailed(job.output) }
        guard writer.startWriting() else { throw writer.error ?? ReelError.writeFailed(job.output) }
        writer.startSession(atSourceTime: .zero)

        // 4. Pump every output into its input concurrently.
        let total = max(duration.seconds, 0.001)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await pump(videoOut, into: videoIn, label: "video") { t in progress(min(t.seconds / total, 1)) }
            }
            for (i, (out, _)) in audioOuts.enumerated() {
                let input = audioIns[i]
                group.addTask { try await pump(out, into: input, label: "audio\(i)") { _ in } }
            }
            try await group.waitForAll()
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? ReelError.writeFailed(job.output)
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? ReelError.writeFailed(job.output) }
        progress(1)
    }

    private static func pump(
        _ output: AVAssetReaderOutput,
        into input: AVAssetWriterInput,
        label: String,
        onTime: @escaping @Sendable (CMTime) -> Void
    ) async throws {
        let queue = DispatchQueue(label: "dev.reel.finish.\(label)")
        nonisolated(unsafe) let output = output
        nonisolated(unsafe) let input = input
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                    onTime(CMSampleBufferGetPresentationTimeStamp(sample))
                    if !input.append(sample) {
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                }
            }
        }
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
