import AVFoundation
import CoreImage
import Foundation
import VideoToolbox

/// Turns a `Recording` into the final file:
/// joins pause segments, mixes system audio + mic into one AAC track (most
/// players only play the first audio track), and optionally applies per-frame
/// effects (auto-zoom, smoothed cursor). Video is passed through untouched
/// unless effects are on.
public enum Finisher {
    /// A per-frame image transform plus a cheap description of what it looks
    /// like at a given time. Frames whose source and signature haven't changed
    /// are skipped (the previous frame simply lasts longer), which matters
    /// because hardware encoding is the bottleneck and screen content is
    /// mostly still.
    public struct FrameEffect: Sendable {
        public var render: @Sendable (CIImage, CMTime) -> CIImage
        /// Equal signatures at two times ⇒ identical output for the same source frame.
        /// nil means "always render".
        public var signature: (@Sendable (Double) -> [Double])?

        public init(render: @escaping @Sendable (CIImage, CMTime) -> CIImage,
                    signature: (@Sendable (Double) -> [Double])? = nil) {
            self.render = render
            self.signature = signature
        }
    }

    public struct Job: Sendable {
        public var segments: [URL]
        public var output: URL
        public var format: VideoFormat = .mp4
        public var mergeAudio = true
        public var effect: FrameEffect?
        /// Frame rate effects animate at. ScreenCaptureKit only delivers frames
        /// when the screen changes, so effects are rendered on a fixed clock
        /// (skipping ticks where nothing changes).
        public var frameRate = 60

        public init(segments: [URL], output: URL) {
            self.segments = segments
            self.output = output
        }
    }

    /// One shared GPU context; no color management (screen pixels are already
    /// display-referred) and no intermediate caching (every frame is new).
    static let renderContext = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
        .cacheIntermediates: false,
    ])

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
        var renderSize = CGSize.zero
        if job.effect != nil {
            // NV12 end to end: decoder → Core Image (GPU) → hardware encoder.
            videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: Self.nv12)
            let size = try await videoTrack.load(.naturalSize)
            renderSize = size
            let codec: AVVideoCodecType = formatHint.map { CMFormatDescriptionGetMediaSubType($0) } == kCMVideoCodecType_HEVC ? .hevc : .h264
            let fps = Double(job.frameRate)
            videoSettings = [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    // Screen content is mostly static; ~0.1 bit/pixel/frame stays crisp.
                    AVVideoAverageBitRateKey: Int(size.width * size.height * fps * 0.1),
                    AVVideoExpectedSourceFrameRateKey: fps,
                    // We're not live: favor throughput.
                    kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String: true,
                    kVTCompressionPropertyKey_RealTime as String: false,
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
        let adaptor = job.effect == nil ? nil : AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoIn,
            sourcePixelBufferAttributes: Self.nv12.merging([
                kCVPixelBufferWidthKey as String: Int(renderSize.width),
                kCVPixelBufferHeightKey as String: Int(renderSize.height),
            ]) { $1 }
        )
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
            if let effect = job.effect, let adaptor {
                let fps = job.frameRate
                group.addTask {
                    await render(videoOut, through: effect, into: adaptor, frameRate: fps, duration: duration) { t in
                        progress(min(t / total, 1))
                    }
                }
            } else {
                group.addTask {
                    try await pump(videoOut, into: videoIn, label: "video") { t in progress(min(t.seconds / total, 1)) }
                }
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
        // With skipped frames the last one may start well before the end;
        // ending the session there keeps the full duration.
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? ReelError.writeFailed(job.output) }
        progress(1)
    }

    static let nv12: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]

    /// Steps a fixed `frameRate` clock across the video. At each tick the
    /// latest source frame is drawn through `effect`, unless neither the
    /// source nor the effect's signature changed since the last emitted frame,
    /// in which case the tick is skipped.
    private static func render(
        _ output: AVAssetReaderOutput,
        through effect: FrameEffect,
        into adaptor: AVAssetWriterInputPixelBufferAdaptor,
        frameRate: Int,
        duration: CMTime,
        onTime: @escaping @Sendable (Double) -> Void
    ) async {
        let queue = DispatchQueue(label: "dev.reel.finish.render")
        nonisolated(unsafe) let output = output
        nonisolated(unsafe) let adaptor = adaptor
        nonisolated(unsafe) let input = adaptor.assetWriterInput
        let context = renderContext
        let end = duration.seconds
        let tick = 1 / Double(frameRate)

        nonisolated(unsafe) var pending = output.copyNextSampleBuffer()
        nonisolated(unsafe) var current: CMSampleBuffer?
        nonisolated(unsafe) var lastSignature: [Double]?
        nonisolated(unsafe) var emitted = false
        nonisolated(unsafe) var lastEmit = -Double.infinity
        nonisolated(unsafe) var i = 0
        // Ticks needed regardless of change: ~1 fps during still stretches (so
        // players can scrub) and the very last tick (so the video ends on a frame).
        let heartbeat = 1.0
        let lastTick = max(0, Int((end / tick).rounded(.up)) - 1)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    let t = Double(i) * tick
                    guard t < end else {
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                    // Advance to the newest source frame at or before this tick.
                    var newSource = false
                    while let p = pending, CMSampleBufferGetPresentationTimeStamp(p).seconds <= t + tick / 2 {
                        current = p
                        pending = output.copyNextSampleBuffer()
                        newSource = true
                    }
                    i += 1
                    guard let current, let source = CMSampleBufferGetImageBuffer(current) else { continue }
                    let signature = effect.signature?(t)
                    let required = t - lastEmit >= heartbeat || i - 1 == lastTick
                    if emitted, !newSource, !required, let signature, signature == lastSignature { continue }

                    var out: CVPixelBuffer?
                    guard let pool = adaptor.pixelBufferPool,
                          CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out
                    else { continue }
                    CVBufferPropagateAttachments(source, out)
                    let image = CIImage(cvPixelBuffer: source)
                    let time = CMTime(value: CMTimeValue(i - 1), timescale: CMTimeScale(frameRate))
                    let rendered = effect.render(image, time).cropped(to: image.extent)
                    context.render(rendered, to: out, bounds: image.extent, colorSpace: nil)
                    if !adaptor.append(out, withPresentationTime: time) {
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                    lastSignature = signature
                    emitted = true
                    lastEmit = t
                    onTime(t)
                }
            }
        }
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
