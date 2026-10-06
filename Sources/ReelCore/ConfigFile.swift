import Foundation

/// The config file on disk: loading, in-place edits that keep comments, and live reload.
public final class ConfigFile: @unchecked Sendable {
    public let url: URL
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "dev.reel.config-watch")

    public init(url: URL = ConfigFile.defaultURL) {
        self.url = url
    }

    /// `$XDG_CONFIG_HOME/reel/config`, else `~/.config/reel/config`.
    public static var defaultURL: URL {
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config", directoryHint: .isDirectory)
        }
        return base.appending(path: "reel/config")
    }

    /// Writes the commented template if there's no file yet.
    public func ensureExists() throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Config.template.write(to: url, atomically: true, encoding: .utf8)
    }

    public func load() -> (Config, [Config.Warning]) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (Config(), []) }
        return Config.parse(text)
    }

    /// Sets one key, editing the file in place so comments and order survive.
    public func set(_ key: String, _ value: String) throws {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? Config.template
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.setting(key, value, in: text).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Pure version of `set`: replaces the last active `key = …` line, else
    /// uncomments the template's `# key = …` line, else appends.
    public static func setting(_ key: String, _ value: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let newLine = "\(key) = \(value)"

        if let i = lines.lastIndex(where: { Config.splitLine($0)?.0 == key }) {
            let indent = lines[i].prefix { $0 == " " || $0 == "\t" }
            lines[i] = indent + newLine
            return lines.joined(separator: "\n")
        }
        if let i = lines.lastIndex(where: { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("#") else { return false }
            return Config.splitLine(String(t.dropFirst()))?.0 == key
        }) {
            lines[i] = newLine
            return lines.joined(separator: "\n")
        }
        if let last = lines.last, last.isEmpty { lines.removeLast() }
        lines.append(newLine)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: Watching

    /// Calls `onChange` (on the main queue) whenever the file is saved, including
    /// editors that save by writing a new file and renaming it over the old one.
    public func watch(_ onChange: @escaping @Sendable () -> Void) {
        queue.async { self.startWatching(onChange) }
    }

    private func startWatching(_ onChange: @escaping @Sendable () -> Void) {
        source?.cancel()
        source = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // File missing (mid-save or deleted): try again shortly.
            queue.asyncAfter(deadline: .now() + 0.5) { self.startWatching(onChange) }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let replaced = !src.data.isDisjoint(with: [.delete, .rename])
            self.pending?.cancel()
            let work = DispatchWorkItem { DispatchQueue.main.async(execute: onChange) }
            self.pending = work
            self.queue.asyncAfter(deadline: .now() + 0.15, execute: work)
            if replaced {
                self.queue.asyncAfter(deadline: .now() + 0.1) { self.startWatching(onChange) }
            }
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }
}
