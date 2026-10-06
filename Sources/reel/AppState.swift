import AVFoundation
import Combine
import ReelCore

@MainActor
final class AppState: ObservableObject {
    /// Preferences from ~/.config/reel/config; reloaded whenever the file is saved.
    @Published private(set) var config = Config()
    @Published private(set) var configWarnings: [Config.Warning] = []
    /// Last-used toggles and regions (UserDefaults).
    @Published var session: SessionState {
        didSet { if session != oldValue { session.save() } }
    }

    @Published var isRecording = false
    @Published var isPaused = false

    let configFile = ConfigFile()

    init() {
        session = SessionState.load()
        try? configFile.ensureExists()
        reloadConfig()
    }

    func reloadConfig() {
        let (config, warnings) = configFile.load()
        if config != self.config { self.config = config }
        configWarnings = warnings
    }

    /// Writes one key to the config file (in place) and applies it immediately.
    func set(_ key: String, _ value: String) {
        do {
            try configFile.set(key, value)
            reloadConfig()
        } catch {
            Toast.error("Couldn't write config: \(error.localizedDescription)")
        }
    }

    func set(_ key: String, _ value: Bool) { set(key, value ? "true" : "false") }

    var captureOptions: CaptureOptions { session.captureOptions(config: config) }

    func saveDirectory(for kind: SaveLocation.Kind) -> URL {
        SaveLocation.directory(for: kind, override: config.saveDirectory)
    }

    var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    var cameras: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external], mediaType: .video, position: .unspecified).devices
    }
}
