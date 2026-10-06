import AVFoundation
import Foundation
import ScreenCaptureKit

/// Records a capture target straight to a .mov via SCRecordingOutput.
/// Video, system audio and microphone land as separate tracks.
public final class Recorder: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var url: URL?
    private var finish: CheckedContinuation<URL, Error>?
    private let sampleQueue = DispatchQueue(label: "dev.reel.samples")

    public private(set) var startedAt: Date?
    /// Called when capture ends on its own (display unplugged, window closed, permission revoked).
    public var onUnexpectedStop: ((Error) -> Void)?
    public var isRecording: Bool { lock.withLock { stream != nil } }

    public override init() { super.init() }

    public func start(
        _ target: CaptureTarget,
        options: CaptureOptions,
        to url: URL,
        keepWindows: [CGWindowID] = []
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
        if options.systemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        if options.microphone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
        }

        let rc = SCRecordingOutputConfiguration()
        rc.outputURL = url
        rc.outputFileType = .mov
        // HEVC handles 5K/6K displays; H.264's hardware encoder tops out at 4096 wide.
        rc.videoCodecType = .hevc
        let output = SCRecordingOutput(configuration: rc, delegate: self)
        try stream.addRecordingOutput(output)

        lock.withLock {
            self.stream = stream
            self.output = output
            self.url = url
        }
        do {
            try await stream.startCapture()
            startedAt = .now
        } catch {
            reset()
            throw error
        }
    }

    /// Stops capture and returns the finished file once the writer has flushed it.
    public func stop() async throws -> URL {
        guard let (stream, url) = lock.withLock({ self.stream.map { ($0, self.url!) } }) else {
            throw ReelError.notRecording
        }
        return try await withCheckedThrowingContinuation { cont in
            lock.withLock { finish = cont }
            Task {
                do {
                    try await stream.stopCapture()
                } catch {
                    self.complete(.failure(error))
                    return
                }
                // Fallback in case the finish callback never arrives.
                try? await Task.sleep(for: .seconds(3))
                if FileManager.default.fileExists(atPath: url.path) {
                    self.complete(.success(url))
                }
            }
        }
    }

    private func complete(_ result: Result<URL, Error>) {
        let cont = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            let c = finish
            finish = nil
            return c
        }
        guard let cont else {
            if case .failure(let error) = result, isRecording {
                reset()
                onUnexpectedStop?(error)
            }
            return
        }
        reset()
        cont.resume(with: result)
    }

    private func reset() {
        lock.withLock {
            stream = nil
            output = nil
            url = nil
        }
        startedAt = nil
    }
}

extension Recorder: SCStreamDelegate, SCStreamOutput, SCRecordingOutputDelegate {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        complete(.failure(error))
    }

    public func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        guard let url = lock.withLock({ self.url }) else { return }
        complete(.success(url))
    }

    public func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        complete(.failure(error))
    }
}
