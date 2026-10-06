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

    func start(over rect: NSRect) {
        guard mode != .off else { return }
        if !Self.hasPermission {
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

    private func handle(_ key: (text: String, isShortcut: Bool, isPrintable: Bool)) {
        if key.isShortcut {
            model.show(key.text, append: false)
        } else if mode == .all {
            model.show(key.text, append: key.isPrintable && model.isTyping)
            model.isTyping = key.isPrintable
        } else {
            return
        }
        hideTask?.cancel()
        hideTask = Task { [model] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(Design.animation) { model.text = nil }
            model.isTyping = false
        }
    }

    private nonisolated static let special: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Space: "Space",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    /// "⌘⇧K", "↩", or a typed character.
    nonisolated static func describe(_ e: NSEvent) -> (text: String, isShortcut: Bool, isPrintable: Bool) {
        let f = e.modifierFlags
        let hasCommandish = f.contains(.command) || f.contains(.control) || f.contains(.option)
        var mods = ""
        if f.contains(.control) { mods += "⌃" }
        if f.contains(.option) { mods += "⌥" }
        if f.contains(.shift) && (hasCommandish || special[Int(e.keyCode)] != nil) { mods += "⇧" }
        if f.contains(.command) { mods += "⌘" }
        if let s = special[Int(e.keyCode)] {
            return (mods + s, true, false)
        }
        if hasCommandish {
            let key = (e.charactersIgnoringModifiers ?? "").uppercased()
            return (mods + (key.isEmpty ? "?" : key), true, false)
        }
        return (e.characters ?? "", false, true)
    }
}

@MainActor
private final class KeystrokeModel: ObservableObject {
    @Published var text: String?
    var isTyping = false

    func show(_ s: String, append: Bool) {
        withAnimation(Design.animation) {
            if append, let t = text { text = String((t + s).suffix(32)) } else { text = s }
        }
    }
}

private struct KeystrokeView: View {
    @ObservedObject var model: KeystrokeModel

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            if let text = model.text {
                Text(text)
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
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
