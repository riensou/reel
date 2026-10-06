import AVFoundation
import Foundation
import QuartzCore
import ScreenCaptureKit

/// What a finished capture session produced, before the Finisher turns it into one file.
public struct Recording: Sendable {
    /// One file per stretch between pauses, in order.
    public let segments: [URL]
    public let options: CaptureOptions
    public let workDirectory: URL
}

/// Records a capture target via SCRecordingOutput. Pausing ends the current
/// segment file; resuming starts a new one on the still-running stream, so
/// resume is instant. Video, system audio and mic land as separate tracks;
/// `Finisher` joins segments and mixes the audio.
public final class Recorder: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var stream: SCStream?
    private var options = CaptureOptions()
    private var workDir: URL?
    private var codec: AVVideoCodecType = .h264
    private var fileType: AVFileType = .mp4
    private var current: SCRecordingOutput?
    private var segments: [URL] = []
    private var finishWaiters: [ObjectIdentifier: CheckedContinuation<Void, Error>] = [:]
    private let sampleQueue = DispatchQueue(label: "dev.reel.samples")

    // Active-time clock (excludes pauses), on CACurrentMediaTime.
    private var activeSince: CFTimeInterval?
    private var accumulated: CFTimeInterval = 0

    /// Captured frame size in pixels, and pixels per point, of the current recording.
    public private(set) var frameSize: CGSize = .zero
    public private(set) var pointScale: CGFloat = 1

    /// Called when capture ends on its own (display unplugged, window closed, permission revoked).
    public var onUnexpectedStop: ((Error) -> Void)?

    public override init() { super.init() }

    public var isRecording: Bool { lock.withLock { stream != nil } }
    public var isPaused: Bool { lock.withLock { stream != nil && current == nil } }

    /// Seconds of recorded (non-paused) time so far.
    public var activeTime: TimeInterval {
        lock.withLock { accumulated + (activeSince.map { CACurrentMediaTime() - $0 } ?? 0) }
    }

    public func start(
        _ target: CaptureTarget,
        options: CaptureOptions,
        keepWindows: [CGWindowID] = [],
        startPaused: Bool = false
    ) async throws {
        guard !isRecording else { throw ReelError.alreadyRecording }
        if options.microphone, AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        let (filter, config) = try await StreamSetup.make(target: target, options: options, keepWindows: keepWindows)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        // SCRecordingOutput does the writing; these outputs only exist so SCK doesn't
        // log "stream output NOT found" for every dropped sample.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if options.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue) }
        if options.microphone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue) }

        let dir = SaveLocation.workDirectory()
        lock.withLock {
            self.stream = stream
            self.options = options
            self.workDir = dir
            self.segments = []
            self.accumulated = 0
            self.codec = Self.codec(for: options.codec, width: config.width, height: config.height)
            self.fileType = options.format == .mp4 ? .mp4 : .mov
        }
        frameSize = CGSize(width: config.width, height: config.height)
        pointScale = CGFloat(filter.pointPixelScale)
        do {
            // Starting paused lets a countdown run while the stream warms up;
            // resume() then begins writing instantly.
            if !startPaused { try beginSegment(on: stream) }
            try await stream.startCapture()
            if !startPaused { lock.withLock { activeSince = CACurrentMediaTime() } }
        } catch {
            reset()
            throw error
        }
    }

    public func pause() async throws {
        guard let (stream, output) = lock.withLock({ () -> (SCStream, SCRecordingOutput)? in
            guard let s = stream, let o = current else { return nil }
            return (s, o)
        }) else { return }
        lock.withLock {
            current = nil
            if let since = activeSince { accumulated += CACurrentMediaTime() - since }
            activeSince = nil
        }
        try await finish(output) { try stream.removeRecordingOutput(output) }
    }

    public func resume() throws {
        guard let stream = lock.withLock({ self.current == nil ? self.stream : nil }) else { return }
        try beginSegment(on: stream)
        lock.withLock { activeSince = CACurrentMediaTime() }
    }

    /// Stops capture and returns the segments once every file has been flushed.
    public func stop() async throws -> Recording {
        guard let (stream, output) = lock.withLock({ () -> (SCStream, SCRecordingOutput?)? in
            stream.map { ($0, current) }
        }) else { throw ReelError.notRecording }
        lock.withLock {
            if let since = activeSince { accumulated += CACurrentMediaTime() - since }
            activeSince = nil
            current = nil
        }
        if let output {
            try await finish(output) { try await stream.stopCapture() }
        } else {
            try? await stream.stopCapture()
        }
        let recording = lock.withLock {
            Recording(segments: segments.filter { FileManager.default.fileExists(atPath: $0.path) },
                      options: options, workDirectory: workDir!)
        }
        reset()
        guard !recording.segments.isEmpty else { throw ReelError.notRecording }
        return recording
    }

    /// Stops and throws everything away.
    public func cancel() async {
        let (stream, dir) = lock.withLock { (self.stream, self.workDir) }
        try? await stream?.stopCapture()
        reset()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: Internals

    private func beginSegment(on stream: SCStream) throws {
        let (url, codec, fileType) = lock.withLock { () -> (URL, AVVideoCodecType, AVFileType) in
            let ext = self.fileType == .mp4 ? "mp4" : "mov"
            let url = workDir!.appending(path: "segment-\(segments.count).\(ext)")
            segments.append(url)
            return (url, self.codec, self.fileType)
        }
        let rc = SCRecordingOutputConfiguration()
        rc.outputURL = url
        rc.outputFileType = fileType
        rc.videoCodecType = codec
        let output = SCRecordingOutput(configuration: rc, delegate: self)
        try stream.addRecordingOutput(output)
        lock.withLock { current = output }
    }

    /// Runs `trigger` and waits until `output` has finished writing its file.
    private func finish(_ output: SCRecordingOutput, trigger: @escaping @Sendable () async throws -> Void) async throws {
        let id = ObjectIdentifier(output)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.withLock { finishWaiters[id] = cont }
            Task {
                do {
                    try await trigger()
                } catch {
                    self.resolve(id, .failure(error))
                    return
                }
                // Fallback in case the finish callback never arrives.
                try? await Task.sleep(for: .seconds(3))
                self.resolve(id, .success(()))
            }
        }
    }

    private func resolve(_ id: ObjectIdentifier, _ result: Result<Void, Error>) {
        let cont = lock.withLock { finishWaiters.removeValue(forKey: id) }
        cont?.resume(with: result)
    }

    private func reset() {
        lock.withLock {
            stream = nil
            current = nil
            workDir = nil
            activeSince = nil
        }
    }

    /// H.264 when it fits the hardware encoder (≤ 4096×2304 worth of pixels), else HEVC.
    static func codec(for preference: VideoCodec, width: Int, height: Int) -> AVVideoCodecType {
        switch preference {
        case .h264: return .h264
        case .hevc: return .hevc
        case .auto:
            let fits = max(width, height) <= 4096 && width * height <= 4096 * 2304
            return fits ? .h264 : .hevc
        }
    }
}

extension Recorder: SCStreamDelegate, SCStreamOutput, SCRecordingOutputDelegate {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            let w = Array(finishWaiters.values)
            finishWaiters.removeAll()
            return w
        }
        if waiters.isEmpty, isRecording {
            reset()
            onUnexpectedStop?(error)
        }
        waiters.forEach { $0.resume(throwing: error) }
    }

    public func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        resolve(ObjectIdentifier(recordingOutput), .success(()))
    }

    public func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        resolve(ObjectIdentifier(recordingOutput), .failure(error))
    }
}
