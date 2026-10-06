import AVFoundation
import AppKit
import ReelCore

/// The floating bottom-right preview. The capture sits in a temp file until the
/// thumbnail times out, is swiped away, clicked, or dragged — then it's moved into
/// the save folder, exactly like ⌘⇧5.
@MainActor
final class ThumbnailController {
    private var current: ThumbnailPanel?

    func present(tempURL: URL, destination: URL, seconds: Double) async {
        current?.commit()
        let image = await Self.preview(for: tempURL)
        let panel = ThumbnailPanel(tempURL: tempURL, destination: destination, image: image, seconds: seconds)
        panel.onClose = { [weak self, weak panel] in
            if self?.current === panel { self?.current = nil }
        }
        current = panel
        panel.present(on: NSScreen.underMouse ?? NSScreen.screens[0])
    }

    private static func preview(for url: URL) async -> NSImage {
        if url.pathExtension == "mov" {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 600, height: 600)
            if let (cg, _) = try? await gen.image(at: .zero) {
                return NSImage(cgImage: cg, size: .zero)
            }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path)
    }
}

final class ThumbnailPanel: NSPanel {
    let tempURL: URL
    let destination: URL
    let seconds: Double
    var onClose: (() -> Void)?

    private(set) var savedURL: URL?
    private var timer: Timer?
    private var restingFrame: NSRect = .zero

    init(tempURL: URL, destination: URL, image: NSImage, seconds: Double) {
        self.tempURL = tempURL
        self.destination = destination
        self.seconds = seconds
        let bound = NSSize(width: 200, height: 140)
        let s = image.size
        let ratio = min(bound.width / max(s.width, 1), bound.height / max(s.height, 1))
        let size = NSSize(width: max(60, (s.width * ratio).rounded()), height: max(40, (s.height * ratio).rounded()))
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = ThumbnailView(image: image, isVideo: tempURL.pathExtension == "mov", panel: self)
    }

    func present(on screen: NSScreen) {
        let vf = screen.visibleFrame
        restingFrame = NSRect(x: vf.maxX - frame.width - 18, y: vf.minY + 18, width: frame.width, height: frame.height)
        setFrame(restingFrame.offsetBy(dx: frame.width + 40, dy: 0), display: false)
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(restingFrame, display: true)
        }
        startTimer()
    }

    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.commit() }
        }
    }

    func pauseTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Moves the file into the save folder (once) and returns where it ended up.
    @discardableResult
    func save() -> URL? {
        if let savedURL { return savedURL }
        do {
            savedURL = try SaveLocation.commit(tempURL, to: destination)
        } catch {
            NSSound.beep()
            NSLog("reel: couldn't save \(tempURL.path): \(error)")
        }
        return savedURL
    }

    /// Save and slide away.
    func commit() {
        save()
        dismiss()
    }

    func discard() {
        pauseTimer()
        if savedURL == nil { try? FileManager.default.removeItem(at: tempURL) }
        if let savedURL { try? FileManager.default.trashItem(at: savedURL, resultingItemURL: nil) }
        dismiss()
    }

    private func dismiss() {
        pauseTimer()
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().setFrame(restingFrame.offsetBy(dx: frame.width + 40, dy: 0), display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.orderOut(nil)
                self?.onClose?()
            }
        })
    }
}

private final class ThumbnailView: NSView, NSDraggingSource {
    weak var panel: ThumbnailPanel?
    private let image: NSImage
    private var mouseDownAt: NSPoint?
    private var swipeX: CGFloat = 0

    init(image: NSImage, isVideo: Bool, panel: ThumbnailPanel) {
        self.image = image
        self.panel = panel
        super.init(frame: NSRect(origin: .zero, size: panel.frame.size))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
        layer?.contents = image
        layer?.contentsGravity = .resizeAspectFill
        if isVideo {
            let badge = NSImageView(image: NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "Video")!)
            badge.symbolConfiguration = .init(pointSize: 28, weight: .regular)
            badge.contentTintColor = .white
            badge.frame = NSRect(x: (bounds.width - 32) / 2, y: (bounds.height - 32) / 2, width: 32, height: 32)
            badge.shadow = {
                let s = NSShadow()
                s.shadowBlurRadius = 4
                s.shadowColor = .black.withAlphaComponent(0.5)
                return s
            }()
            addSubview(badge)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { panel?.pauseTimer() }
    override func mouseExited(with event: NSEvent) { if panel?.isVisible == true { panel?.startTimer() } }

    override func mouseDown(with event: NSEvent) {
        mouseDownAt = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownAt else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4, let url = panel?.save() else { return }
        mouseDownAt = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
        panel?.alphaValue = 0.3
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownAt != nil else { return }
        mouseDownAt = nil
        if let url = panel?.save() {
            NSWorkspace.shared.open(url)
        }
        panel?.commit()
    }

    override func scrollWheel(with event: NSEvent) {
        // Two-finger swipe right dismisses (and saves), like the system thumbnail.
        swipeX += event.scrollingDeltaX
        if event.phase == .ended || event.momentumPhase == .began {
            if swipeX < -30 || swipeX > 30 { panel?.commit() }
            swipeX = 0
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        panel?.pauseTimer()
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(open), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show in Finder", action: #selector(reveal), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy", action: #selector(copyFile), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete", action: #selector(delete), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        if panel?.isVisible == true { panel?.startTimer() }
    }

    @objc private func open() {
        if let url = panel?.save() { NSWorkspace.shared.open(url) }
        panel?.commit()
    }

    @objc private func reveal() {
        if let url = panel?.save() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        panel?.commit()
    }

    @objc private func copyFile() {
        guard let url = panel?.save() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if url.pathExtension == "png", let img = NSImage(contentsOf: url) {
            pb.writeObjects([img, url as NSURL])
        } else {
            pb.writeObjects([url as NSURL])
        }
        panel?.commit()
    }

    @objc private func delete() {
        panel?.discard()
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        panel?.alphaValue = 1
        panel?.commit()
    }
}
