import AVFoundation
import Combine
import ReelCore

@MainActor
final class AppState: ObservableObject {
    @Published var prefs: Preferences {
        didSet { if prefs != oldValue { prefs.save() } }
    }
    @Published var isRecording = false
    @Published var recordingStartedAt: Date?

    init() {
        prefs = Preferences.load()
    }

    var microphones: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    func saveDirectory(for kind: SaveLocation.Kind) -> URL {
        SaveLocation.directory(for: kind, override: prefs.saveDirectory)
    }
}
