import Foundation

public enum SaveLocation {
    public enum Kind: Sendable { case screenshot, recording }

    /// Resolves the folder captures land in: the user's override, else the macOS
    /// screenshot location (the same one ⌘⇧5 uses), else the Desktop.
    public static func directory(for kind: Kind, override: String? = nil) -> URL {
        let fm = FileManager.default
        if let override, !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let specific = kind == .screenshot ? "location-screenshot" : "location-screenrecording"
        for key in [specific, "location"] {
            let value = CFPreferencesCopyAppValue(key as CFString, "com.apple.screencapture" as CFString)
            if let path = value as? String, !path.isEmpty {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    return url
                }
            }
        }
        return fm.homeDirectoryForCurrentUser.appending(path: "Desktop", directoryHint: .isDirectory)
    }

    /// "Screenshot 2026-10-06 at 14.03.22.png", matching macOS naming.
    public static func filename(for kind: Kind, date: Date = .now, format: VideoFormat = .mp4) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = f.string(from: date)
        switch kind {
        case .screenshot: return "Screenshot \(stamp).png"
        case .recording: return "Screen Recording \(stamp).\(format.rawValue)"
        }
    }

    /// Scratch location for a capture that hasn't been "committed" by the thumbnail yet.
    public static func temporaryURL(for kind: Kind, date: Date = .now, format: VideoFormat = .mp4) -> URL {
        let dir = workDirectory()
        return dir.appending(path: filename(for: kind, date: date, format: format))
    }

    /// Removes scratch directories left behind by crashes or failed sessions.
    public static func cleanStaleWork(olderThan age: TimeInterval = 6 * 3600) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "reel", directoryHint: .isDirectory)
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for dir in dirs {
            let modified = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date.now.timeIntervalSince(modified) > age { try? fm.removeItem(at: dir) }
        }
    }

    /// A fresh scratch directory (segments, intermediate files).
    public static func workDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "reel/\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Moves `source` into `directory`, appending " (2)", " (3)"… if the name is taken.
    @discardableResult
    public static func commit(_ source: URL, to directory: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var dest = directory.appending(path: source.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = directory.appending(path: "\(base) (\(n)).\(ext)")
            n += 1
        }
        try fm.moveItem(at: source, to: dest)
        return dest
    }
}
