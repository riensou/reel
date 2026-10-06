import AppKit
import SwiftUI

/// Quiet, non-modal feedback: a material pill at the top-center of the active
/// screen. Fades after 4s (paused while hovered); up to 3 stack. reel excludes
/// its own windows from capture, so toasts never end up in recordings.
@MainActor
enum Toast {
    struct Action {
        let title: String
        let run: () -> Void
    }

    private static var panels: [NSPanel] = []

    static func info(_ message: String, icon: String = "checkmark.circle.fill", action: Action? = nil) {
        show(message, icon: icon, tint: .secondary, action: action)
    }

    static func error(_ message: String, action: Action? = nil) {
        show(message, icon: "exclamationmark.triangle.fill", tint: .orange, action: action)
    }

    /// Maps capture errors to friendlier text, with a fix-it button for permissions.
    static func error(_ error: Error) {
        if !CGPreflightScreenCaptureAccess() {
            Toast.error("reel needs Screen Recording permission", action: .openPrivacy("Privacy_ScreenCapture"))
        } else {
            Toast.error(error.localizedDescription)
        }
    }

    private static func show(_ message: String, icon: String, tint: Color, action: Action?) {
        if panels.count >= 3 { dismiss(panels[0]) }
        var panelRef: NSPanel?
        let view = ToastView(message: message, icon: icon, tint: tint, action: action.map { a in
            Action(title: a.title) {
                a.run()
                if let p = panelRef { dismiss(p) }
            }
        }, onExpire: {
            if let p = panelRef { dismiss(p) }
        })
        let panel = FloatingPanel(level: .statusBar) { view }
        panelRef = panel
        panel.hasShadow = false
        panels.append(panel)
        layout(animatedNew: panel)
    }

    private static func layout(animatedNew new: NSPanel? = nil) {
        guard let screen = NSScreen.underMouse ?? NSScreen.main else { return }
        var y = screen.visibleFrame.maxY - 12
        for panel in panels.reversed() {
            let size = (panel.contentView as? NSHostingView<ToastView>)?.fittingSize ?? panel.frame.size
            y -= size.height
            let frame = NSRect(x: screen.frame.midX - size.width / 2, y: y, width: size.width, height: size.height)
            y -= 8
            if panel === new {
                panel.setFrame(frame.offsetBy(dx: 0, dy: Design.reduceMotion ? 0 : 8), display: false)
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    panel.animator().setFrame(frame, display: true)
                    panel.animator().alphaValue = 1
                }
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    panel.animator().setFrame(frame, display: true)
                }
            }
        }
    }

    private static func dismiss(_ panel: NSPanel) {
        guard let i = panels.firstIndex(of: panel) else { return }
        panels.remove(at: i)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
        layout()
    }
}

extension Toast.Action {
    static func openPrivacy(_ pane: String) -> Toast.Action {
        Toast.Action(title: "Open Settings") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    static func reveal(_ url: URL) -> Toast.Action {
        Toast.Action(title: "Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}

private struct ToastView: View {
    let message: String
    let icon: String
    let tint: Color
    let action: Toast.Action?
    let onExpire: () -> Void

    @State private var hovering = false
    @State private var remaining: Double = 4

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(message)
                .font(.system(size: 13))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action: action.run) {
                    Text(action.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .reelSurface(radius: 18)
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(16) // room for the shadow inside the borderless panel
        .onHover { hovering = $0 }
        .task {
            while remaining > 0 {
                try? await Task.sleep(for: .milliseconds(100))
                if !hovering { remaining -= 0.1 }
            }
            onExpire()
        }
    }
}
