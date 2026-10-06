import AppKit
import ReelCore

extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
    }

    static var underMouse: NSScreen? {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main
    }
}

/// Full-screen picker shown on every display: drag out a region, or hover + click a window.
/// Esc cancels.
@MainActor
final class SelectionOverlay {
    enum Kind { case region, window }

    private var panels: [NSPanel] = []
    private var continuation: CheckedContinuation<CaptureTarget?, Never>?

    func select(_ kind: Kind) async -> CaptureTarget? {
        await withCheckedContinuation { cont in
            continuation = cont
            for screen in NSScreen.screens {
                let panel = OverlayPanel(screen: screen)
                let view = OverlayView(kind: kind, screen: screen) { [weak self] target in
                    self?.finish(target)
                }
                panel.contentView = view
                panel.orderFrontRegardless()
                panels.append(panel)
                if screen == NSScreen.underMouse {
                    panel.makeKey()
                    panel.makeFirstResponder(view)
                }
            }
            NSApp.activate()
        }
    }

    private func finish(_ target: CaptureTarget?) {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        continuation?.resume(returning: target)
        continuation = nil
    }
}

final class OverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
}

private final class OverlayView: NSView {
    let kind: SelectionOverlay.Kind
    let screen: NSScreen
    let onFinish: (CaptureTarget?) -> Void

    private var dragStart: NSPoint?
    private var dragRect: NSRect?
    private var hover: (id: CGWindowID, rect: NSRect)?

    init(kind: SelectionOverlay.Kind, screen: NSScreen, onFinish: @escaping (CaptureTarget?) -> Void) {
        self.kind = kind
        self.screen = screen
        self.onFinish = onFinish
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        (kind == .region ? NSCursor.crosshair : NSCursor.pointingHand).set()
    }

    override func draw(_ dirtyRect: NSRect) {
        switch kind {
        case .region:
            NSColor.black.withAlphaComponent(0.25).setFill()
            bounds.fill()
            guard let r = dragRect else { return }
            NSColor.clear.setFill()
            r.fill(using: .copy)
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
            path.lineWidth = 1
            path.stroke()
            drawLabel("\(Int(r.width)) × \(Int(r.height))", near: r)
        case .window:
            guard let h = hover else { return }
            NSColor.systemBlue.withAlphaComponent(0.25).setFill()
            h.rect.fill()
            NSColor.systemBlue.setStroke()
            let path = NSBezierPath(rect: h.rect)
            path.lineWidth = 2
            path.stroke()
        }
    }

    private func drawLabel(_ text: String, near r: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        var origin = NSPoint(x: r.maxX - size.width - 6, y: r.minY - size.height - 8)
        if origin.y < 4 { origin.y = r.minY + 6 }
        let bg = NSRect(x: origin.x - 5, y: origin.y - 2, width: size.width + 10, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
        s.draw(at: origin)
    }

    // MARK: Region

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch kind {
        case .region:
            dragStart = p
        case .window:
            if let h = hover { onFinish(.window(h.id)) }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard kind == .region, let start = dragStart else { return }
        var p = convert(event.locationInWindow, from: nil)
        p.x = min(max(p.x, 0), bounds.maxX)
        p.y = min(max(p.y, 0), bounds.maxY)
        dragRect = NSRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard kind == .region else { return }
        defer { dragStart = nil }
        guard let r = dragRect, r.width >= 4, r.height >= 4 else {
            dragRect = nil
            needsDisplay = true
            return
        }
        // View space is bottom-left; ScreenCaptureKit wants display points, top-left.
        let flipped = CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
        onFinish(.region(screen.displayID, flipped))
    }

    // MARK: Window

    override func mouseMoved(with event: NSEvent) {
        guard kind == .window else { return }
        let found = Self.window(at: NSEvent.mouseLocation)
        let rect = found.map { r -> NSRect in
            let local = r.rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            return local
        }
        if found?.id != hover?.id || rect != hover?.rect {
            hover = found.flatMap { f in rect.map { (f.id, $0) } }
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if kind == .window {
            hover = nil
            needsDisplay = true
        }
    }

    /// Topmost normal-layer window under a global (bottom-left origin) point, in the same space.
    private static func window(at point: NSPoint) -> (id: CGWindowID, rect: NSRect)? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgPoint = CGPoint(x: point.x, y: primaryHeight - point.y)
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != pid,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: boundsDict),
                  b.contains(cgPoint), b.width > 40, b.height > 40
            else { continue }
            return (id, NSRect(x: b.minX, y: primaryHeight - b.maxY, width: b.width, height: b.height))
        }
        return nil
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish(nil) } // Esc
    }

    override func cancelOperation(_ sender: Any?) {
        onFinish(nil)
    }
}
