import AppKit
import ReelCore

/// One recording, from countdown to saved file: overlays (border, keystrokes,
/// webcam), the event log for demo effects, pause/resume, and finishing.
@MainActor
final class RecordingSession {
    private let state: AppState
    private let target: CaptureTarget
    private let config: Config
    private let options: CaptureOptions
    private let recorder = Recorder()
    private let thumbnails: ThumbnailController
    private let webcam: WebcamBubble
    private var border: RecordingBorder?
    private var keystrokes: KeystrokeHUD?
    private var events: EventRecorder?
    private var stopping = false

    /// Called once the session is over (saved, cancelled or failed).
    var onEnd: (() -> Void)?

    init(state: AppState, target: CaptureTarget, thumbnails: ThumbnailController, webcam: WebcamBubble) {
        self.state = state
        self.target = target
        self.thumbnails = thumbnails
        self.webcam = webcam
        config = state.config
        options = state.captureOptions
    }

    var elapsed: TimeInterval { recorder.activeTime }

    func start() async {
        let rect = CaptureGeometry.nsRect(for: target) ?? NSScreen.main?.frame ?? .zero

        // Overlays that belong in the video must exist before the stream's
        // content filter is built so they can be kept.
        if config.showKeystrokes != .off {
            let hud = KeystrokeHUD(mode: config.showKeystrokes)
            hud.start(over: rect)
            keystrokes = hud
        }
        let keep = [keystrokes?.windowID, webcam.windowID].compactMap { $0 }

        recorder.onUnexpectedStop = { [weak self] error in
            DispatchQueue.main.async {
                Toast.error(error)
                self?.teardown()
            }
        }

        // The stream warms up while the countdown runs; writing starts at 0.
        let countdown = config.countdown
        do {
            try await recorder.start(target, options: options, keepWindows: keep, startPaused: countdown > 0)
        } catch {
            Toast.error(error)
            teardown()
            return
        }
        if countdown > 0 {
            guard await Countdown().run(seconds: countdown, over: rect) else {
                await recorder.cancel()
                teardown()
                return
            }
            do { try recorder.resume() } catch {
                Toast.error(error)
                await recorder.cancel()
                teardown()
                return
            }
        }

        // Full-screen recordings don't need an outline.
        if config.recordingBorder, !target.isDisplay {
            let b = RecordingBorder(target: target)
            b.show()
            border = b
        }
        if config.autoZoom || config.smoothCursor {
            let ev = EventRecorder(target: target, frameSize: recorder.frameSize, scale: recorder.pointScale) { [recorder] in
                (recorder.activeTime, !recorder.isPaused)
            }
            ev.start()
            events = ev
        }
        state.isRecording = true
        state.isPaused = false
    }

    func togglePause() {
        Task {
            do {
                if recorder.isPaused {
                    try recorder.resume()
                    state.isPaused = false
                } else {
                    try await recorder.pause()
                    state.isPaused = true
                }
            } catch {
                Toast.error(error)
            }
        }
    }

    func stop() {
        guard !stopping else { return }
        stopping = true
        Task {
            let recording: Recording
            do {
                recording = try await recorder.stop()
            } catch {
                Toast.error(error)
                teardown()
                return
            }
            let log = events?.stop()
            events = nil
            teardown()
            await finish(recording, log: log)
        }
    }

    func cancel() {
        guard !stopping else { return }
        stopping = true
        _ = events?.stop()
        events = nil
        Task {
            await recorder.cancel()
            teardown()
            Toast.info("Recording discarded", icon: "trash")
        }
    }

    private func teardown() {
        border?.hide()
        border = nil
        keystrokes?.stop()
        keystrokes = nil
        webcam.hide()
        state.isRecording = false
        state.isPaused = false
        onEnd?()
        onEnd = nil
    }

    // MARK: Finishing

    private func finish(_ recording: Recording, log: EventLog?) async {
        let out = SaveLocation.temporaryURL(for: .recording, format: options.format)
        var job = Finisher.Job(segments: recording.segments, output: out)
        job.format = options.format
        job.mergeAudio = config.mergeAudioTracks
        if let log {
            job.effect = DemoEffects.make(
                log: log, autoZoom: config.autoZoom, zoomScale: config.autoZoomScale,
                smoothCursor: config.smoothCursor && state.session.showCursor
            )
        }
        let dir = state.saveDirectory(for: .recording)
        defer { try? FileManager.default.removeItem(at: recording.workDirectory) }

        if await Finisher.canSkip(job) {
            do {
                try FileManager.default.moveItem(at: recording.segments[0], to: out)
            } catch {
                Toast.error(error)
                return
            }
            await deliver(out, to: dir)
            return
        }

        // Show the thumbnail right away with progress while finishing.
        let panel: ThumbnailPanel? = config.thumbnail
            ? await thumbnails.presentProcessing(previewFrom: recording.segments[0], destination: dir, seconds: config.thumbnailDuration)
            : nil
        do {
            try await Finisher.run(job) { p in
                Task { @MainActor in panel?.setProgress(p) }
            }
        } catch {
            // Never lose a recording: fall back to the raw first segment.
            Toast.error("Couldn't finish the recording (\(error.localizedDescription)); saved the raw capture instead")
            try? FileManager.default.removeItem(at: out)
            try? FileManager.default.moveItem(at: recording.segments[0], to: out)
        }
        if let panel {
            panel.ready(out)
        } else {
            await deliver(out, to: dir)
        }
    }

    private func deliver(_ url: URL, to dir: URL) async {
        if config.thumbnail {
            await thumbnails.present(tempURL: url, destination: dir, seconds: config.thumbnailDuration)
        } else {
            do {
                let saved = try SaveLocation.commit(url, to: dir)
                Toast.info("Saved \(saved.lastPathComponent)", icon: "checkmark.circle.fill", action: .reveal(saved))
            } catch {
                Toast.error(error)
            }
        }
    }
}

private extension CaptureTarget {
    var isDisplay: Bool {
        if case .display = self { return true }
        return false
    }
}
