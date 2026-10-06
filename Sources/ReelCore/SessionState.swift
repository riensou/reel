import ColorSync
import CoreGraphics
import Foundation

/// What you last chose — remembered between launches, but not "preferences", so
/// it lives in UserDefaults rather than the config file.
public struct SessionState: Codable, Equatable, Sendable {
    public var mode: CaptureMode = .region
    public var action: CaptureAction = .screenshot
    public var systemAudio = false
    public var microphone = false
    /// AVCaptureDevice.uniqueID; nil = system default.
    public var microphoneID: String?
    public var showCursor = true
    public var webcamOn = false
    public var cameraID: String?
    /// Last region per display, keyed by the display's stable UUID string.
    public var lastRegions: [String: CGRect] = [:]
    /// Webcam bubble center, as a fraction of the screen's visible frame.
    public var webcamPosition: CGPoint?

    public init() {}

    private static let key = "session"

    public static func load(from defaults: UserDefaults = .standard) -> SessionState {
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(SessionState.self, from: data)
        else { return SessionState() }
        return state
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key)
        }
    }

    /// Recording options from the current toggles plus config-level settings.
    public func captureOptions(config: Config) -> CaptureOptions {
        var o = CaptureOptions()
        o.systemAudio = systemAudio
        o.microphone = microphone
        o.microphoneID = microphoneID
        o.cursor.show = showCursor && !config.smoothCursor
        o.fps = config.fps
        o.format = config.videoFormat
        o.codec = config.videoCodec
        return o
    }
}

extension CGDirectDisplayID {
    /// Survives reboots and replugging, unlike the display ID itself.
    public var stableUUID: String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(self)?.takeRetainedValue() else { return String(self) }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
