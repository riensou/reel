import Foundation

/// User preferences, read from a ghostty-style `key = value` file.
/// See `Config.template` for the documented list of keys.
public struct Config: Equatable, Sendable {
    public enum Keystrokes: String, CaseIterable, Sendable { case off, shortcuts, all }
    public enum WebcamSize: String, CaseIterable, Sendable { case small, medium, large }
    public enum WebcamShape: String, CaseIterable, Sendable { case circle, rounded }

    /// nil = the macOS screenshot location.
    public var saveDirectory: String?
    public var videoFormat: VideoFormat = .mp4
    public var videoCodec: VideoCodec = .auto
    public var fps = 60
    public var mergeAudioTracks = true
    public var thumbnail = true
    public var thumbnailDuration: Double = 5
    public var hotkey = KeyCombo.defaultToolbar
    public var launchAtLogin = false
    public var countdown = 0
    public var recordingBorder = false
    public var showKeystrokes: Keystrokes = .off
    public var webcam = false
    public var webcamSize: WebcamSize = .medium
    public var webcamShape: WebcamShape = .circle
    public var autoZoom = false
    public var autoZoomScale: Double = 1.8
    public var smoothCursor = false

    public init() {}

    public struct Warning: Equatable, Sendable, CustomStringConvertible {
        public let line: Int
        public let message: String
        public var description: String { "line \(line): \(message)" }
    }

    /// Later lines win, like ghostty. Unknown keys and bad values become warnings
    /// and leave the default in place.
    public static func parse(_ text: String) -> (Config, [Warning]) {
        var config = Config()
        var warnings: [Warning] = []
        for (i, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            guard let (key, value) = splitLine(rawLine) else { continue }
            guard let spec = Key.byName[key] else {
                warnings.append(Warning(line: i + 1, message: "unknown key '\(key)'"))
                continue
            }
            if !spec.apply(&config, value) {
                warnings.append(Warning(line: i + 1, message: "invalid value '\(value)' for \(key) (\(spec.allowed))"))
            }
        }
        return (config, warnings)
    }

    /// The value of `key` as it would be written in the file.
    public func value(for key: String) -> String? {
        Key.byName[key]?.read(self)
    }

    /// `key = value` → (key, value); nil for blanks and comments.
    /// A ` #` (space-hash) starts an inline comment.
    static func splitLine(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
        var value = String(trimmed[trimmed.index(after: eq)...])
        if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]) }
        value = value.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return key.isEmpty ? nil : (key, value)
    }
}

// MARK: - Key table

extension Config {
    /// One entry per config key: its docs, how to read it, how to apply a value.
    public struct Key: Sendable {
        public let name: String
        public let doc: String
        public let allowed: String
        let read: @Sendable (Config) -> String
        let apply: @Sendable (inout Config, String) -> Bool

        public static let all: [Key] = [
            Key("save-directory", "Where captures are saved. 'system' follows the macOS screenshot location.",
                "system | a folder path",
                read: { $0.saveDirectory ?? "system" },
                apply: { c, v in
                    c.saveDirectory = (v.isEmpty || v == "system") ? nil : v
                    return true
                }),
            enumKey("video-format", "Container for recordings.", \.videoFormat),
            enumKey("video-codec", "auto = H.264 up to 4096 px wide, HEVC above.", \.videoCodec),
            intKey("fps", "Recording frame rate.", \.fps, 1...120),
            boolKey("merge-audio-tracks", "Mix mic + system audio into one track (plays everywhere).", \.mergeAudioTracks),
            boolKey("thumbnail", "Show the floating preview before saving.", \.thumbnail),
            Key("thumbnail-duration", "Seconds the preview stays before the file is saved.", "1-60",
                read: { formatNumber($0.thumbnailDuration) },
                apply: { c, v in
                    guard let d = Double(v), (1...60).contains(d) else { return false }
                    c.thumbnailDuration = d
                    return true
                }),
            Key("hotkey", "Opens the toolbar; stops a recording in progress.", "e.g. cmd+shift+6",
                read: { $0.hotkey.description },
                apply: { c, v in
                    guard let k = KeyCombo(v) else { return false }
                    c.hotkey = k
                    return true
                }),
            boolKey("launch-at-login", "Start reel when you log in.", \.launchAtLogin),
            intKey("countdown", "Seconds of 3-2-1 before recording starts. 0 = off.", \.countdown, 0...10),
            boolKey("recording-border", "Outline the recorded area while recording (not captured).", \.recordingBorder),
            enumKey("show-keystrokes", "Show pressed keys in recordings. Needs Accessibility permission.", \.showKeystrokes),
            boolKey("webcam", "Adds a camera toggle to the toolbar for a webcam bubble.", \.webcam),
            enumKey("webcam-size", "Size of the webcam bubble.", \.webcamSize),
            enumKey("webcam-shape", "Shape of the webcam bubble.", \.webcamShape),
            boolKey("auto-zoom", "Zoom in on clicks after recording (re-encodes the video).", \.autoZoom),
            Key("auto-zoom-scale", "How far auto-zoom zooms in.", "1.2-3",
                read: { formatNumber($0.autoZoomScale) },
                apply: { c, v in
                    guard let d = Double(v), (1.2...3).contains(d) else { return false }
                    c.autoZoomScale = d
                    return true
                }),
            boolKey("smooth-cursor", "Redraw the cursor along a smoothed path after recording.", \.smoothCursor),
        ]

        public static let byName: [String: Key] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

        init(_ name: String, _ doc: String, _ allowed: String,
             read: @escaping @Sendable (Config) -> String,
             apply: @escaping @Sendable (inout Config, String) -> Bool) {
            self.name = name
            self.doc = doc
            self.allowed = allowed
            self.read = read
            self.apply = apply
        }

        static func boolKey(_ name: String, _ doc: String, _ path: WritableKeyPath<Config, Bool> & Sendable) -> Key {
            Key(name, doc, "true | false",
                read: { $0[keyPath: path] ? "true" : "false" },
                apply: { c, v in
                    switch v.lowercased() {
                    case "true", "yes", "on", "1": c[keyPath: path] = true
                    case "false", "no", "off", "0": c[keyPath: path] = false
                    default: return false
                    }
                    return true
                })
        }

        static func intKey(_ name: String, _ doc: String, _ path: WritableKeyPath<Config, Int> & Sendable,
                           _ range: ClosedRange<Int>) -> Key {
            Key(name, doc, "\(range.lowerBound)-\(range.upperBound)",
                read: { String($0[keyPath: path]) },
                apply: { c, v in
                    guard let n = Int(v), range.contains(n) else { return false }
                    c[keyPath: path] = n
                    return true
                })
        }

        static func enumKey<E: RawRepresentable & CaseIterable & Sendable>(
            _ name: String, _ doc: String, _ path: WritableKeyPath<Config, E> & Sendable
        ) -> Key where E.RawValue == String {
            Key(name, doc, E.allCases.map(\.rawValue).joined(separator: " | "),
                read: { $0[keyPath: path].rawValue },
                apply: { c, v in
                    guard let e = E(rawValue: v.lowercased()) else { return false }
                    c[keyPath: path] = e
                    return true
                })
        }
    }

    /// The file written on first launch: every key commented out at its default.
    public static var template: String {
        let defaults = Config()
        var out = """
        # reel configuration
        #
        # Syntax: `key = value`, one per line. Lines starting with # are comments.
        # reel reloads this file whenever it's saved, and the Settings window
        # edits it in place. Uncomment a line to change it.

        """
        for key in Key.all {
            out += "\n# \(key.doc)\n# Values: \(key.allowed)\n# \(key.name) = \(key.read(defaults))\n"
        }
        return out
    }
}

private func formatNumber(_ d: Double) -> String {
    d == d.rounded() ? String(Int(d)) : String(d)
}
