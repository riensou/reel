import Foundation

/// Everything the user can configure, persisted as one JSON blob in the app's defaults.
public struct Preferences: Codable, Equatable, Sendable {
    public var mode: CaptureMode = .region
    public var action: CaptureAction = .screenshot
    public var options = CaptureOptions()
    public var showThumbnail = true
    public var thumbnailSeconds: Double = 5
    /// nil means "wherever macOS screenshots go" (com.apple.screencapture location).
    public var saveDirectory: String?

    public init() {}

    private static let key = "preferences"

    public static func load(from defaults: UserDefaults = .standard) -> Preferences {
        guard let data = defaults.data(forKey: key),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: data)
        else { return Preferences() }
        return prefs
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
