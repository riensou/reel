@preconcurrency import ScreenCaptureKit

/// Live system-audio level for the toolbar's speaker button. ScreenCaptureKit is the
/// only no-driver way to hear system output, so this runs an audio-only stream
/// (with a 2×2 px, 1 fps video stream it requires but ignores).
@MainActor
final class SystemAudioMonitor {
    let meter = LevelMeter()
    private var stream: SCStream?
    private var isStarting = false
    /// Bumped by every start/stop so a slow startup can tell it's been superseded.
    private var generation = 0
    private let output: StreamTap

    init() {
        output = StreamTap()
        output.onSample = { [meter] in meter.push($0) }
    }

    func start() {
        guard stream == nil, !isStarting else { return }
        isStarting = true
        generation += 1
        let gen = generation
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let display = content.displays.first
            else {
                if gen == generation { isStarting = false }
                return
            }
            let config = SCStreamConfiguration()
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.showsCursor = false
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
            do {
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
                try await stream.startCapture()
            } catch {
                if gen == generation { isStarting = false }
                return
            }
            // stop() (or a restart) happened while we were starting up.
            guard gen == generation else {
                try? await stream.stopCapture()
                return
            }
            isStarting = false
            self.stream = stream
            meter.activate()
        }
    }

    func stop() {
        generation += 1
        isStarting = false
        meter.reset()
        guard let stream else { return }
        self.stream = nil
        Task { try? await stream.stopCapture() }
    }
}

private final class StreamTap: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.reel.system-level")
    var onSample: ((CMSampleBuffer) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { onSample?(sampleBuffer) }
    }
}
