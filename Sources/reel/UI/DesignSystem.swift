import AppKit
import SwiftUI

/// Shared look for every reel surface: material, 12pt radius, hairline border.
enum Design {
    static let panelRadius: CGFloat = 12
    static let controlRadius: CGFloat = 8
    static let hairline = Color.primary.opacity(0.08)

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Standard ease-out; a plain fade-length when Reduce Motion is on.
    static var animation: Animation { reduceMotion ? .linear(duration: 0.15) : .easeOut(duration: 0.2) }
}

extension View {
    /// Floating-surface styling used by the toolbar, toasts, pills and HUDs.
    func reelSurface(radius: CGFloat = Design.panelRadius) -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Design.hairline))
    }
}

/// Borderless, transparent, non-activating panel that hosts SwiftUI — the base for
/// every floating reel surface.
class FloatingPanel<Content: View>: NSPanel {
    let host: NSHostingView<Content>

    init(level: NSWindow.Level = .floating, canKey: Bool = false, @ViewBuilder content: () -> Content) {
        host = NSHostingView(rootView: content())
        self.canKey = canKey
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        host.sizingOptions = [.intrinsicContentSize]
        contentView = host
    }

    private let canKey: Bool
    override var canBecomeKey: Bool { canKey }

    var fittingSize: NSSize { host.fittingSize }
}
