import AppKit
import QuartzCore

/// Click-through overlay that draws an expanding ring wherever the mouse is clicked.
/// It's a reel window that is deliberately *not* excluded from capture, so rings
/// show up in the recording.
@MainActor
final class ClickHighlighter {
    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var monitor: Any?

    var windowIDs: [CGWindowID] { panels.values.map { CGWindowID($0.windowNumber) } }

    func start() {
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.setFrame(screen.frame, display: false)
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            panel.contentView = view
            panel.orderFrontRegardless()
            panels[screen.displayID] = panel
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let right = event.type == .rightMouseDown
            MainActor.assumeIsolated { self?.pulse(at: NSEvent.mouseLocation, right: right) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    private func pulse(at point: NSPoint, right: Bool) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
              let layer = panels[screen.displayID]?.contentView?.layer else { return }
        let local = CGPoint(x: point.x - screen.frame.minX, y: point.y - screen.frame.minY)
        let radius: CGFloat = 22
        let ring = CAShapeLayer()
        ring.frame = CGRect(x: local.x - radius, y: local.y - radius, width: radius * 2, height: radius * 2)
        ring.path = CGPath(ellipseIn: ring.bounds, transform: nil)
        let color = right ? NSColor.systemPink : NSColor.systemYellow
        ring.fillColor = color.withAlphaComponent(0.25).cgColor
        ring.strokeColor = color.cgColor
        ring.lineWidth = 3
        ring.opacity = 0
        layer.addSublayer(ring)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4
        scale.toValue = 1.2
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.0, 1.0, 0.0]
        fade.keyTimes = [0, 0.15, 1]
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.55
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "pulse")
        CATransaction.commit()
    }
}
