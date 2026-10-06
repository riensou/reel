import AVFoundation
import CoreImage
import Testing
@testable import ReelCore

@Suite struct FinisherTests {
    @Test func joinsSegmentsAndMergesAudio() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = dir.appending(path: "segment-0.mp4")
        let b = dir.appending(path: "segment-1.mp4")
        try await makeClip(a, seconds: 1.0, audioTracks: 2)
        try await makeClip(b, seconds: 0.5, audioTracks: 2)

        var job = Finisher.Job(segments: [a, b], output: dir.appending(path: "out.mp4"))
        #expect(await !Finisher.canSkip(job))
        try await Finisher.run(job)

        let out = AVURLAsset(url: job.output)
        let video = try await out.loadTracks(withMediaType: .video)
        let audio = try await out.loadTracks(withMediaType: .audio)
        #expect(video.count == 1)
        #expect(audio.count == 1)
        let duration = try await out.load(.duration).seconds
        #expect(abs(duration - 1.5) < 0.1)

        // Keeping tracks separate passes both through.
        job.mergeAudio = false
        job.output = dir.appending(path: "separate.mp4")
        try await Finisher.run(job)
        #expect(try await AVURLAsset(url: job.output).loadTracks(withMediaType: .audio).count == 2)
    }

    @Test func singleSegmentWithOneTrackIsSkipped() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "segment-0.mp4")
        try await makeClip(a, seconds: 0.3, audioTracks: 1)
        #expect(await Finisher.canSkip(Finisher.Job(segments: [a], output: dir.appending(path: "o.mp4"))))
    }

    @Test func effectRendersAndReencodes() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appending(path: "segment-0.mp4")
        try await makeClip(a, seconds: 0.5, audioTracks: 0)
        var job = Finisher.Job(segments: [a], output: dir.appending(path: "fx.mp4"))
        job.effect = { image, _ in image.transformed(by: CGAffineTransform(scaleX: 2, y: 2)) }
        try await Finisher.run(job)
        let tracks = try await AVURLAsset(url: job.output).loadTracks(withMediaType: .video)
        #expect(try await tracks.first?.load(.naturalSize) == CGSize(width: 320, height: 240))
    }
}

/// A 320×240 test clip with one audio track, in `dir`.
func makeTestClip(in dir: URL, seconds: Double) async throws -> URL {
    let url = dir.appending(path: "src-\(UUID().uuidString).mp4")
    try await makeClip(url, seconds: seconds, audioTracks: 1)
    return url
}

/// Writes a small H.264 clip with `audioTracks` sine-wave AAC tracks.
private func makeClip(_ url: URL, seconds: Double, audioTracks: Int) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240,
    ])
    writer.add(video)
    var audios: [AVAssetWriterInput] = []
    for _ in 0..<audioTracks {
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
        ])
        a.expectsMediaDataInRealTime = false
        writer.add(a)
        audios.append(a)
    }
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)

    // Feed all inputs concurrently: AVAssetWriter interleaves tracks, so
    // writing one track to completion first would stall.
    nonisolated(unsafe) let adaptorRef = adaptor
    nonisolated(unsafe) let videoRef = video
    nonisolated(unsafe) let audioRefs = audios
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            let fps = 30
            let frames = Int(seconds * Double(fps))
            let context = CIContext()
            for i in 0..<frames {
                while !videoRef.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
                var pb: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, adaptorRef.pixelBufferPool!, &pb)
                let shade = CGFloat(i) / CGFloat(frames)
                context.render(CIImage(color: CIColor(red: shade, green: 0.3, blue: 0.6))
                    .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 240)), to: pb!)
                adaptorRef.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
            }
            videoRef.markAsFinished()
        }
        for (t, input) in audioRefs.enumerated() {
            group.addTask {
                let rate = 48_000.0
                let totalSamples = Int(seconds * rate)
                var written = 0
                while written < totalSamples {
                    while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
                    let n = min(1024, totalSamples - written)
                    input.append(try sineBuffer(start: written, count: n, freq: 440 * Double(t + 1), rate: rate))
                    written += n
                }
                input.markAsFinished()
            }
        }
        try await group.waitForAll()
    }
    await writer.finishWriting()
    #expect(writer.status == .completed)
}

private func sineBuffer(start: Int, count: Int, freq: Double, rate: Double) throws -> CMSampleBuffer {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
    )
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                   magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    var samples = [Float](repeating: 0, count: count * 2)
    for i in 0..<count {
        let v = Float(sin(2 * .pi * freq * Double(start + i) / rate) * 0.3)
        samples[2 * i] = v
        samples[2 * i + 1] = v
    }
    var block: CMBlockBuffer?
    let bytes = samples.count * 4
    CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                       customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
    samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes) }
    var sb: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: count,
        presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(rate)),
        packetDescriptions: nil, sampleBufferOut: &sb
    )
    return sb!
}
