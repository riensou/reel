@preconcurrency import AVFoundation
import AppKit
import ReelCore

/// Floating webcam preview that's included in recordings. Drag to move (snaps to
/// the nearest corner); right-click for size and shape.
@MainActor
final class WebcamBubble {
    private let state: AppState
    private var panel: BubblePanel?
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "dev.reel.webcam")

    init(state: AppState) {
        self.state = state
    }

    var isVisible: Bool { panel != nil }
    var windowID: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }

    func show() {
        Task { await showWhenReady() }
    }

    /// Shows the bubble, asking for camera access first if needed. Returns once
    /// the bubble is on screen (or couldn't be shown), so a recording can wait
    /// for it before deciding which windows to capture.
    @discardableResult
    func showWhenReady() async -> Bool {
        guard panel == nil else { return true }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { return false }
            guard panel == nil else { return true }
        default:
            Toast.error("reel needs Camera permission for the webcam bubble", action: .openPrivacy("Privacy_Camera"))
            return false
        }
        let device = state.session.cameraID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .video)
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else {
            Toast.error("No camera found")
            return false
        }
        let session = AVCaptureSession()
        session.sessionPreset = .high
        guard session.canAddInput(input) else { return false }
        session.addInput(input)
        self.session = session

        let panel = BubblePanel(size: bubbleSize, shape: state.config.webcamShape, session: session)
        panel.onMoved = { [weak self] in self?.snap() }
        panel.onMenu = { [weak self] event in self?.showMenu(event) }
        self.panel = panel
        panel.setFrameOrigin(restingOrigin(for: panel.frame.size))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        // (Explicit completion handler: inside async code the trailing-closure
        // form resolves to the async overload.)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 1 }, completionHandler: nil)
        queue.async { session.startRunning() }
        return true
    }

    func hide() {
        guard let panel else { return }
        self.panel = nil
        let session = self.session
        self.session = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 },
                                            completionHandler: { panel.orderOut(nil) })
        queue.async { session?.stopRunning() }
    }

    /// Re-applies size/shape after a config change.
    func refresh() {
        guard isVisible else { return }
        hide()
        show()
    }

    private var bubbleSize: NSSize {
        let d: CGFloat = switch state.config.webcamSize {
        case .small: 120
        case .medium: 180
        case .large: 260
        }
        return state.config.webcamShape == .circle ? NSSize(width: d, height: d) : NSSize(width: d * 4 / 3, height: d)
    }

    private var screen: NSScreen { NSScreen.underMouse ?? NSScreen.screens[0] }

    private func restingOrigin(for size: NSSize) -> NSPoint {
        let vf = screen.visibleFrame
        let inset: CGFloat = 24
        let f = state.session.webcamPosition ?? CGPoint(x: 1, y: 0) // bottom-right
        let x = f.x > 0.5 ? vf.maxX - size.width - inset : vf.minX + inset
        let y = f.y > 0.5 ? vf.maxY - size.height - inset : vf.minY + inset
        return NSPoint(x: x, y: y)
    }

    private func snap() {
        guard let panel else { return }
        let vf = screen.visibleFrame
        state.session.webcamPosition = CGPoint(x: panel.frame.midX > vf.midX ? 1 : 0, y: panel.frame.midY > vf.midY ? 1 : 0)
        let target = restingOrigin(for: panel.frame.size)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Design.reduceMotion ? 0 : 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(target)
        }
    }

    private func showMenu(_ event: NSEvent) {
        guard let view = panel?.contentView else { return }
        let menu = NSMenu()
        for size in Config.WebcamSize.allCases {
            let item = menu.addItem(withTitle: size.rawValue.capitalized, action: nil, keyEquivalent: "")
            item.state = state.config.webcamSize == size ? .on : .off
            item.representedObject = size
        }
        menu.addItem(.separator())
        for shape in Config.WebcamShape.allCases {
            let item = menu.addItem(withTitle: shape == .circle ? "Circle" : "Rounded Rectangle", action: nil, keyEquivalent: "")
            item.state = state.config.webcamShape == shape ? .on : .off
            item.representedObject = shape
        }
        let cameras = state.cameras
        if cameras.count > 1 {
            menu.addItem(.separator())
            for cam in cameras {
                let item = menu.addItem(withTitle: cam.localizedName, action: nil, keyEquivalent: "")
                item.state = (state.session.cameraID ?? AVCaptureDevice.default(for: .video)?.uniqueID) == cam.uniqueID ? .on : .off
                item.representedObject = cam.uniqueID
            }
        }
        let handler = MenuHandler { [weak self] item in
            guard let self else { return }
            if let size = item.representedObject as? Config.WebcamSize {
                self.state.set("webcam-size", size.rawValue)
            } else if let shape = item.representedObject as? Config.WebcamShape {
                self.state.set("webcam-shape", shape.rawValue)
            } else if let id = item.representedObject as? String {
                self.state.session.cameraID = id
            }
            self.refresh()
        }
        for item in menu.items where !item.isSeparatorItem {
            item.target = handler
            item.action = #selector(MenuHandler.fire(_:))
        }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        _ = handler // keep alive until the menu closes
    }
}

/// Target/action shim for closure-based menu items.
final class MenuHandler: NSObject {
    let action: (NSMenuItem) -> Void
    init(_ action: @escaping (NSMenuItem) -> Void) { self.action = action }
    @objc func fire(_ sender: NSMenuItem) { action(sender) }
}

private final class BubblePanel: NSPanel {
    var onMoved: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?

    init(size: NSSize, shape: Config.WebcamShape, session: AVCaptureSession) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = BubbleView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        let radius = shape == .circle ? size.height / 2 : 18
        view.layer?.cornerRadius = radius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 1.5
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        view.layer?.backgroundColor = NSColor.black.cgColor
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        if let conn = preview.connection, conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = true
        }
        view.layer?.addSublayer(preview)
        view.onMouseUp = { [weak self] in self?.onMoved?() }
        view.onRightClick = { [weak self] e in self?.onMenu?(e) }
        contentView = view
    }
}

private final class BubbleView: NSView {
    var onMouseUp: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    private var grab: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        grab = event.locationInWindow
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab, let window else { return }
        let p = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: p.x - grab.x, y: p.y - grab.y))
    }

    override func mouseUp(with event: NSEvent) {
        grab = nil
        NSCursor.pop()
        onMouseUp?()
    }

    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }
}
