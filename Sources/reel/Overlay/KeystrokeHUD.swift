import AppKit
import Carbon.HIToolbox
import ReelCore
import SwiftUI

/// Shows pressed keys near the bottom of the recorded area — included in the
/// recording. Needs Accessibility permission to see other apps' key events;
/// macOS never delivers keystrokes from password fields.
@MainActor
final class KeystrokeHUD {
    private let mode: Config.Keystrokes
    private var panel: NSPanel?
    private var monitor: Any?
    private let model = KeystrokeModel()
    private var hideTask: Task<Void, Never>?

    init(mode: Config.Keystrokes) {
        self.mode = mode
    }

    static var hasPermission: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// The window to keep in the capture (call after `start`).
    var windowID: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }

    /// Shows the HUD without listening to the keyboard; feed it with `simulate`.
    /// Used to stage the README demo.
    func startDisplayOnly(over rect: NSRect) {
        start(over: rect, listen: false)
    }

    func simulate(_ key: Key) { handle(key) }

    func start(over rect: NSRect) {
        start(over: rect, listen: true)
    }

    private func start(over rect: NSRect, listen: Bool) {
        guard mode != .off else { return }
        if listen, !Self.hasPermission {
            Toast.error("Keystrokes need Accessibility permission",
                        action: .openPrivacy("Privacy_Accessibility"))
        }
        // The panel stays ordered in (transparent) for the whole recording so
        // ScreenCaptureKit can include it; only its content fades.
        let size = NSSize(width: min(rect.width, 640), height: 90)
        let panel = NSPanel(contentRect: NSRect(x: rect.midX - size.width / 2, y: rect.minY + 24,
                                                width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: KeystrokeView(model: model))
        panel.orderFrontRegardless()
        self.panel = panel

        guard listen else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            let combo = KeystrokeHUD.describe(event)
            MainActor.assumeIsolated { self?.handle(combo) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hideTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }

    enum Key: Equatable {
        /// A combo with ⌘/⌃/⌥, e.g. "⌘⇧K". Always replaces what's shown.
        case shortcut(String)
        /// A named key: Space, ↩, ⇥, ⌫, arrows…
        case named(String)
        /// A typed character.
        case char(String)
    }

    private func handle(_ key: Key) {
        switch key {
        case .shortcut(let s):
            model.replace(with: [.init(text: s, isKey: true)])
        case .named(let s) where mode == .all:
            model.append(.init(text: s, isKey: true))
        case .named(let s):
            // In shortcuts mode, a lone Space is just noise.
            guard s != "Space" else { return }
            model.replace(with: [.init(text: s, isKey: true)])
        case .char(let c) where mode == .all:
            model.append(.init(text: c, isKey: false))
        case .char:
            return
        }
        hideTask?.cancel()
        hideTask = Task { [model] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            model.clear()
        }
    }

    private nonisolated static let named: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Space: "Space",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    nonisolated static func describe(_ e: NSEvent) -> Key {
        let f = e.modifierFlags
        let hasCommandish = f.contains(.command) || f.contains(.control) || f.contains(.option)
        var mods = ""
        if f.contains(.control) { mods += "⌃" }
        if f.contains(.option) { mods += "⌥" }
        if f.contains(.shift) && hasCommandish { mods += "⇧" }
        if f.contains(.command) { mods += "⌘" }
        if let name = named[Int(e.keyCode)] {
            return hasCommandish ? .shortcut(mods + name) : .named(name)
        }
        if hasCommandish {
            let key = (e.charactersIgnoringModifiers ?? "").uppercased()
            return .shortcut(mods + (key.isEmpty ? "?" : key))
        }
        return .char(e.characters ?? "")
    }
}

@MainActor
private final class KeystrokeModel: ObservableObject {
    struct Token: Equatable {
        var text: String
        var isKey: Bool
    }

    @Published private(set) var tokens: [Token] = []
    /// True after a shortcut, so the next typed character starts a fresh line.
    private var showingShortcut = false
    private let maxCharacters = 40

    func replace(with tokens: [Token]) {
        withAnimation(Design.animation) { self.tokens = tokens }
        showingShortcut = true
    }

    /// Typing: characters run together into words; named keys (Space, ↩…)
    /// sit between them, e.g. "the Space king Space walked".
    func append(_ token: Token) {
        var t = showingShortcut ? [] : tokens
        showingShortcut = false
        if !token.isKey, let last = t.last, !last.isKey {
            t[t.count - 1].text += token.text
        } else {
            t.append(token)
        }
        // Keep the line short: drop the oldest pieces first.
        while t.map(\.text.count).reduce(0, +) > maxCharacters, t.count > 1 { t.removeFirst() }
        if let first = t.first, !first.isKey, first.text.count > maxCharacters {
            t[0].text = String(first.text.suffix(maxCharacters))
        }
        if tokens.isEmpty {
            withAnimation(Design.animation) { tokens = t }
        } else {
            tokens = t
        }
    }

    func clear() {
        withAnimation(Design.animation) { tokens = [] }
        showingShortcut = false
    }
}

private struct KeystrokeView: View {
    @ObservedObject var model: KeystrokeModel

    /// Typed text in white; key names dimmer and a touch smaller so they read as keys.
    private var line: Text {
        model.tokens.enumerated().reduce(Text("")) { acc, item in
            let (i, token) = item
            guard token.isKey else { return acc + Text(token.text) }
            let pad = model.tokens.count > 1
            let label = (pad && i > 0 ? " " : "") + token.text + (pad && i < model.tokens.count - 1 ? " " : "")
            return acc + Text(label)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(model.tokens.count > 1 ? 0.5 : 1))
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            if !model.tokens.isEmpty {
                line
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .padding(.bottom, 8)
            }
        }
    }
}
