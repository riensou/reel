import Carbon.HIToolbox

/// A global shortcut like `cmd+shift+6`, as written in the config file.
public struct KeyCombo: Equatable, Hashable, Sendable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public var keyCode: Int
    public var modifiers: Modifiers

    public init(keyCode: Int, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let defaultToolbar = KeyCombo(keyCode: kVK_ANSI_6, modifiers: [.command, .shift])

    /// Parses `cmd+shift+6`, `ctrl+opt+r`, `cmd+f5`… Case-insensitive; order doesn't matter.
    public init?(_ string: String) {
        var mods: Modifiers = []
        var key: Int?
        for raw in string.lowercased().split(separator: "+") {
            let part = raw.trimmingCharacters(in: .whitespaces)
            switch part {
            case "cmd", "command", "super": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "opt", "option", "alt": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            default:
                guard key == nil, let code = Self.codes[part] else { return nil }
                key = code
            }
        }
        // A global hotkey without a modifier would swallow normal typing.
        guard let key, !mods.isEmpty else { return nil }
        self.init(keyCode: key, modifiers: mods)
    }

    /// Config-file spelling, e.g. `cmd+shift+6`.
    public var description: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(Self.names[keyCode] ?? "?")
        return parts.joined(separator: "+")
    }

    /// Menu-style spelling, e.g. `⇧⌘6`.
    public var symbols: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + (Self.glyphs[keyCode] ?? (Self.names[keyCode] ?? "?").uppercased())
    }

    public var carbonModifiers: Int {
        var m = 0
        if modifiers.contains(.command) { m |= cmdKey }
        if modifiers.contains(.shift) { m |= shiftKey }
        if modifiers.contains(.option) { m |= optionKey }
        if modifiers.contains(.control) { m |= controlKey }
        return m
    }

    public static func name(forKeyCode code: Int) -> String? { names[code] }

    // MARK: Key tables

    private static let names: [Int: String] = {
        var t: [Int: String] = [
            kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_E: "e",
            kVK_ANSI_F: "f", kVK_ANSI_G: "g", kVK_ANSI_H: "h", kVK_ANSI_I: "i", kVK_ANSI_J: "j",
            kVK_ANSI_K: "k", kVK_ANSI_L: "l", kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o",
            kVK_ANSI_P: "p", kVK_ANSI_Q: "q", kVK_ANSI_R: "r", kVK_ANSI_S: "s", kVK_ANSI_T: "t",
            kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x", kVK_ANSI_Y: "y",
            kVK_ANSI_Z: "z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Space: "space", kVK_Return: "return", kVK_Tab: "tab", kVK_Escape: "escape",
            kVK_Delete: "backspace", kVK_ForwardDelete: "delete",
            kVK_LeftArrow: "left", kVK_RightArrow: "right", kVK_UpArrow: "up", kVK_DownArrow: "down",
            kVK_ANSI_Minus: "minus", kVK_ANSI_Equal: "equal", kVK_ANSI_LeftBracket: "[",
            kVK_ANSI_RightBracket: "]", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
            kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\",
            kVK_ANSI_Grave: "`",
        ]
        let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19]
        for (i, code) in fkeys.enumerated() { t[code] = "f\(i + 1)" }
        return t
    }()

    private static let codes: [String: Int] = {
        var t = Dictionary(uniqueKeysWithValues: names.map { ($1, $0) })
        t["enter"] = kVK_Return
        t["esc"] = kVK_Escape
        return t
    }()

    private static let glyphs: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑",
        kVK_DownArrow: "↓", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
    ]
}
