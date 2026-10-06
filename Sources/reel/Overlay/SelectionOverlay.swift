import AppKit
import ReelCore
import SwiftUI

extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
    }

    static var underMouse: NSScreen? {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main
    }
}

/// Full-screen picker on every display.
/// - Region: opens with your last region preselected (like ⌘⇧5). Drag inside to
///   move, drag the handles to resize, drag elsewhere for a new region. Enter or
///   the pill's button confirms; Esc cancels. (No double-click-to-confirm: a
///   quick click after drawing should start a move, not capture.)
/// - Window: hover to highlight, click to pick.
@MainActor
final class SelectionOverlay {
    enum Kind { case region, window }

    private var panels: [NSPanel] = []
    private var continuation: CheckedContinuation<CaptureTarget?, Never>?

    /// - Parameters:
    ///   - remembered: last regions keyed by display UUID (display-local points, top-left origin).
    ///   - actionTitle: "Capture" or "Record", shown on the confirm pill.
    func select(_ kind: Kind, remembered: [String: CGRect] = [:], actionTitle: String = "Capture") async -> CaptureTarget? {
        await withCheckedContinuation { cont in
            continuation = cont
            for screen in NSScreen.screens {
                let panel = OverlayPanel(screen: screen)
                let initial = remembered[screen.displayID.stableUUID]
                let view = OverlayView(kind: kind, screen: screen, initial: initial, actionTitle: actionTitle) { [weak self] target in
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

    #if DEBUG
    var viewsForTesting: [OverlayView] { panels.compactMap { $0.contentView as? OverlayView } }
    #endif

    // MARK: Attached to the toolbar (like ⌘⇧5)

    /// Shows the region selection alongside the toolbar: your last region (or
    /// a centered one) is ready to move or resize, and the toolbar's
    /// Capture/Record button uses it. Enter or double-click captures; Esc cancels.
    func attach(remembered: [String: CGRect], onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        let home = NSScreen.underMouse ?? NSScreen.screens[0]
        let regions = remembered
        // No previous selection: start empty and let the user draw one.
        // One selection at a time: prefer the screen under the mouse.
        let selectedScreen = regions[home.displayID.stableUUID] != nil ? home
            : NSScreen.screens.first { regions[$0.displayID.stableUUID] != nil }
        for screen in NSScreen.screens {
            let panel = OverlayPanel(screen: screen)
            let initial = screen == selectedScreen ? regions[screen.displayID.stableUUID] : nil
            let view = OverlayView(kind: .region, screen: screen, initial: initial, actionTitle: "") { target in
                target == nil ? onCancel() : onConfirm()
            }
            view.showsPill = false
            view.onEdit = { [weak self, weak view] in
                // Starting a selection on one display clears it on the others.
                self?.views.filter { $0 !== view }.forEach { $0.clearSelection() }
            }
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }

    /// The region currently selected in attached mode.
    var currentTarget: CaptureTarget? { views.lazy.compactMap(\.currentRegion).first }

    func close() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    private var views: [OverlayView] { panels.compactMap { $0.contentView as? OverlayView } }

    /// Presses the confirm pill programmatically (demo scene).
    func confirmForDemo() {
        panels.compactMap { $0.contentView as? OverlayView }.forEach { $0.confirmIfSelected() }
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
        // Explicitly opaque to the mouse: otherwise macOS sends clicks on the
        // see-through selection straight to the window underneath, and you
        // can't grab the selection to move it.
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
}

final class OverlayView: NSView {
    let kind: SelectionOverlay.Kind
    let screen: NSScreen
    let onFinish: (CaptureTarget?) -> Void
    /// False when attached to the toolbar (its button confirms instead).
    var showsPill = true {
        didSet { layoutPill() }
    }
    /// Called when the user starts changing the selection.
    var onEdit: (() -> Void)?

    // Region state (view coordinates, bottom-left origin).
    private var rect: NSRect?
    private enum Drag { case new(NSPoint), move(NSPoint, NSRect), resize(Handle, NSRect) }
    private var drag: Drag?
    private let pill: NSHostingView<ConfirmPill>
    private let pillModel: PillModel

    // Window state.
    private var hover: (id: CGWindowID, rect: NSRect)?

    private static let handleRadius: CGFloat = 4.5
    private static let snap: CGFloat = 8

    init(kind: SelectionOverlay.Kind, screen: NSScreen, initial: CGRect?, actionTitle: String,
         onFinish: @escaping (CaptureTarget?) -> Void) {
        self.kind = kind
        self.screen = screen
        self.onFinish = onFinish
        pillModel = PillModel(title: actionTitle)
        pill = NSHostingView(rootView: ConfirmPill(model: pillModel))
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        pillModel.confirm = { [weak self] in self?.confirm() }
        pill.isHidden = true
        addSubview(pill)
        if kind == .region, let initial {
            // Display-local top-left → view bottom-left, clamped to this screen.
            let r = NSRect(x: initial.minX, y: bounds.height - initial.maxY, width: initial.width, height: initial.height)
            let clamped = r.intersection(bounds)
            if clamped.width >= 4, clamped.height >= 4 { rect = clamped }
        }
        layoutPill()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        switch kind {
        case .region:
            NSColor.black.withAlphaComponent(0.3).setFill()
            bounds.fill()
            guard let r = rect else { return }
            // Nearly (not fully) transparent: fully clear pixels let clicks fall
            // through to the window below.
            NSColor.black.withAlphaComponent(0.01).setFill()
            r.fill(using: .copy)
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let path = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
            path.lineWidth = 1
            path.stroke()
            for h in Handle.allCases {
                let c = h.point(in: r)
                let dot = NSBezierPath(ovalIn: NSRect(x: c.x - Self.handleRadius, y: c.y - Self.handleRadius,
                                                      width: Self.handleRadius * 2, height: Self.handleRadius * 2))
                NSColor.white.setFill()
                dot.fill()
                NSColor.black.withAlphaComponent(0.35).setStroke()
                dot.lineWidth = 0.5
                dot.stroke()
            }
        case .window:
            guard let h = hover else { return }
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: h.rect, xRadius: 10, yRadius: 10).fill()
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(roundedRect: h.rect.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
            path.lineWidth = 2
            path.stroke()
        }
    }

    private func layoutPill() {
        guard showsPill, kind == .region, let r = rect, drag == nil || { if case .new = drag! { return false } else { return true } }() else {
            pill.isHidden = true
            return
        }
        pillModel.size = "\(Int(r.width)) × \(Int(r.height))"
        let size = pill.fittingSize
        var origin = NSPoint(x: r.midX - size.width / 2, y: r.minY - size.height - 10)
        if origin.y < 8 { origin.y = r.minY + 10 } // no room below: tuck inside
        origin.x = min(max(origin.x, 8), bounds.width - size.width - 8)
        pill.frame = NSRect(origin: origin, size: size)
        pill.isHidden = false
    }

    // MARK: Mouse

    private func handle(at p: NSPoint) -> Handle? {
        guard let r = rect else { return nil }
        return Handle.allCases.first { hypot($0.point(in: r).x - p.x, $0.point(in: r).y - p.y) <= 10 }
    }

    /// Inside the selection or on its edge (a few points either side of the
    /// line) grabs it to move; only the dots resize.
    private func grabsSelection(_ p: NSPoint) -> Bool {
        guard let r = rect else { return false }
        return r.insetBy(dx: -6, dy: -6).contains(p)
    }

    /// The cursor for a point: open hand inside the selection (drag to move),
    /// resize arrows on handles, crosshair elsewhere (drag for a new region).
    private func cursor(at p: NSPoint) -> NSCursor {
        guard kind == .region else { return .pointingHand }
        if case .move = drag { return .closedHand }
        if let h = handle(at: p) { return h.cursor }
        if grabsSelection(p) { return .openHand }
        return .crosshair
    }

    // AppKit resets the cursor on its own schedule; answering cursorUpdate
    // keeps ours from being replaced by the arrow.
    override func cursorUpdate(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        cursor(at: p).set()
        switch kind {
        case .region:
            break
        case .window:
            let found = Self.window(at: NSEvent.mouseLocation)
            let local = found.map { $0.rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }
            if found?.id != hover?.id || local != hover?.rect {
                hover = found.flatMap { f in local.map { (f.id, $0) } }
                needsDisplay = true
            }
        }
    }

    private func trace(_ what: String, _ e: NSEvent, _ p: NSPoint) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["REEL_TRACE"] != nil {
            print(what, "win#", e.windowNumber, "mine#", window?.windowNumber ?? -1, "loc", e.locationInWindow, "view", p,
                  "winFrame", window?.frame ?? .zero, "mouse", NSEvent.mouseLocation)
        }
        #endif
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        trace("down", event, p)
        switch kind {
        case .window:
            if let h = hover { onFinish(.window(h.id)) }
        case .region:
            onEdit?()
            if let h = handle(at: p), let r = rect {
                drag = .resize(h, r)
            } else if let r = rect, grabsSelection(p) {
                drag = .move(p, r)
                NSCursor.closedHand.set()
            } else {
                drag = .new(p)
            }
            layoutPill()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard kind == .region, let drag else { return }
        var p = convert(event.locationInWindow, from: nil)
        trace("drag", event, p)
        p.x = min(max(p.x, 0), bounds.maxX)
        p.y = min(max(p.y, 0), bounds.maxY)
        switch drag {
        case .new(let start):
            rect = snapped(NSRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y)))
        case .move(let start, let orig):
            var r = orig.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            r.origin.x = min(max(r.minX, 0), bounds.width - r.width)
            r.origin.y = min(max(r.minY, 0), bounds.height - r.height)
            rect = snapped(r, keepSize: true)
        case .resize(let h, let orig):
            rect = snapped(h.resize(orig, to: p))
        }
        needsDisplay = true
        layoutPill()
    }

    override func mouseUp(with event: NSEvent) {
        guard kind == .region else { return }
        if case .new = drag, let r = rect, r.width < 4 || r.height < 4 { rect = nil }
        drag = nil
        needsDisplay = true
        layoutPill()
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    /// Pull edges within 8pt onto the screen edges.
    private func snapped(_ r: NSRect, keepSize: Bool = false) -> NSRect {
        var r = r
        let s = Self.snap
        if keepSize {
            if r.minX < s { r.origin.x = 0 }
            if bounds.maxX - r.maxX < s { r.origin.x = bounds.maxX - r.width }
            if r.minY < s { r.origin.y = 0 }
            if bounds.maxY - r.maxY < s { r.origin.y = bounds.maxY - r.height }
            return r
        }
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        if minX < s { minX = 0 }
        if minY < s { minY = 0 }
        if bounds.maxX - maxX < s { maxX = bounds.maxX }
        if bounds.maxY - maxY < s { maxY = bounds.maxY }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func confirmIfSelected() { confirm() }

    /// The selection as a capture target (display points, top-left origin).
    var currentRegion: CaptureTarget? {
        guard kind == .region, let r = rect, r.width >= 4, r.height >= 4 else { return nil }
        return .region(screen.displayID, CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height).integral)
    }

    func clearSelection() {
        rect = nil
        needsDisplay = true
        layoutPill()
    }

    private func confirm() {
        guard kind == .region, let r = rect, r.width >= 4, r.height >= 4 else { return }
        // View space is bottom-left; ScreenCaptureKit wants display points, top-left.
        let flipped = CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height).integral
        onFinish(.region(screen.displayID, flipped))
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: onFinish(nil)              // Esc
        case 36, 76: confirm()              // Return, Enter
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onFinish(nil)
    }

    /// Topmost normal-layer window under a global (bottom-left origin) point, in the same space.
    private static func window(at point: NSPoint) -> (id: CGWindowID, rect: NSRect)? {
        let primaryHeight = CaptureGeometry.primaryHeight
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
            return (id, CaptureGeometry.nsRect(fromCG: b))
        }
        return nil
    }
}

private enum Handle: CaseIterable {
    case bottomLeft, bottom, bottomRight, right, topRight, top, topLeft, left

    func point(in r: NSRect) -> NSPoint {
        switch self {
        case .bottomLeft: NSPoint(x: r.minX, y: r.minY)
        case .bottom: NSPoint(x: r.midX, y: r.minY)
        case .bottomRight: NSPoint(x: r.maxX, y: r.minY)
        case .right: NSPoint(x: r.maxX, y: r.midY)
        case .topRight: NSPoint(x: r.maxX, y: r.maxY)
        case .top: NSPoint(x: r.midX, y: r.maxY)
        case .topLeft: NSPoint(x: r.minX, y: r.maxY)
        case .left: NSPoint(x: r.minX, y: r.midY)
        }
    }

    func resize(_ r: NSRect, to p: NSPoint) -> NSRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch self {
        case .bottomLeft: minX = p.x; minY = p.y
        case .bottom: minY = p.y
        case .bottomRight: maxX = p.x; minY = p.y
        case .right: maxX = p.x
        case .topRight: maxX = p.x; maxY = p.y
        case .top: maxY = p.y
        case .topLeft: minX = p.x; maxY = p.y
        case .left: minX = p.x
        }
        return NSRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    var cursor: NSCursor {
        switch self {
        case .left: .frameResize(position: .left, directions: .all)
        case .right: .frameResize(position: .right, directions: .all)
        case .top: .frameResize(position: .top, directions: .all)
        case .bottom: .frameResize(position: .bottom, directions: .all)
        case .topLeft: .frameResize(position: .topLeft, directions: .all)
        case .topRight: .frameResize(position: .topRight, directions: .all)
        case .bottomLeft: .frameResize(position: .bottomLeft, directions: .all)
        case .bottomRight: .frameResize(position: .bottomRight, directions: .all)
        }
    }
}

@MainActor
private final class PillModel: ObservableObject {
    @Published var size = ""
    let title: String
    var confirm: () -> Void = {}
    init(title: String) { self.title = title }
}

/// "1280 × 720   [Record]" below the selection.
private struct ConfirmPill: View {
    @ObservedObject var model: PillModel

    var body: some View {
        HStack(spacing: 10) {
            Text(model.size)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button(action: model.confirm) {
                Text(model.title)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(model.title == "Record" ? Color.red : Color.accentColor))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .reelSurface(radius: 16)
        .fixedSize()
    }
}
