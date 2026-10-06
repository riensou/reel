import AVFoundation
import AppKit
import ReelCore
import SwiftUI

/// The floating bottom-right preview. The capture sits in a temp file until the
/// thumbnail times out, is swiped away, clicked, or dragged — then it's moved into
/// the save folder, exactly like ⌘⇧5. Recordings that need finishing (merged
/// audio, effects) show a progress ring first.
@MainActor
final class ThumbnailController {
    private var current: ThumbnailPanel?

    /// Shows a ready-to-save capture.
    func present(tempURL: URL, destination: URL, seconds: Double) async {
        let panel = await makePanel(previewFrom: tempURL, destination: destination, seconds: seconds)
        panel.ready(tempURL)
    }

    /// Shows a recording that's still being finished; call `ready` / `failed` on the result.
    func presentProcessing(previewFrom source: URL, destination: URL, seconds: Double) async -> ThumbnailPanel {
        await makePanel(previewFrom: source, destination: destination, seconds: seconds)
    }

    private func makePanel(previewFrom source: URL, destination: URL, seconds: Double) async -> ThumbnailPanel {
        let image = await Self.preview(for: source)
        return present(image: image, isVideo: source.pathExtension != "png", destination: destination, seconds: seconds)
    }

    /// Shows a thumbnail for an already-rendered preview image.
    func present(image: NSImage, isVideo: Bool, destination: URL, seconds: Double) -> ThumbnailPanel {
        current?.commit()
        let panel = ThumbnailPanel(destination: destination, image: image, isVideo: isVideo, seconds: seconds)
        panel.onClose = { [weak self, weak panel] in
            if self?.current === panel { self?.current = nil }
        }
        current = panel
        panel.present(on: NSScreen.underMouse ?? NSScreen.screens[0])
        return panel
    }

    private static func preview(for url: URL) async -> NSImage {
        if url.pathExtension != "png" {
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

@MainActor
final class ThumbnailModel: ObservableObject {
    @Published var progress: Double? = 0
    @Published var exporting: String?
}

final class ThumbnailPanel: NSPanel {
    let destination: URL
    let seconds: Double
    let isVideo: Bool
    var onClose: (() -> Void)?

    private(set) var tempURL: URL?
    private(set) var savedURL: URL?
    private var timer: Timer?
    private var restingFrame: NSRect = .zero
    let model = ThumbnailModel()
    private var busy = false

    var isProcessing: Bool { tempURL == nil && savedURL == nil }

    init(destination: URL, image: NSImage, isVideo: Bool, seconds: Double) {
        self.destination = destination
        self.seconds = seconds
        self.isVideo = isVideo
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
        contentView = ThumbnailView(image: image, isVideo: isVideo, panel: self)
    }

    func present(on screen: NSScreen) {
        let vf = screen.visibleFrame
        restingFrame = NSRect(x: vf.maxX - frame.width - 18, y: vf.minY + 18, width: frame.width, height: frame.height)
        setFrame(restingFrame.offsetBy(dx: Design.reduceMotion ? 0 : frame.width + 40, dy: 0), display: false)
        alphaValue = Design.reduceMotion ? 0 : 1
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(restingFrame, display: true)
            animator().alphaValue = 1
        }
    }

    func setProgress(_ p: Double) { model.progress = p }

    /// The capture is ready to be saved; start the countdown to auto-save.
    func ready(_ url: URL) {
        tempURL = url
        model.progress = nil
        if onReadyCommit {
            save()
            return
        }
        startTimer()
    }

    func failed() {
        dismiss()
    }

    func startTimer() {
        guard !isProcessing, !busy else { return }
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
        guard let tempURL else { return nil }
        do {
            savedURL = try SaveLocation.commit(tempURL, to: destination)
            try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
        } catch {
            Toast.error("Couldn't save: \(error.localizedDescription)")
        }
        return savedURL
    }

    /// Save and slide away. While still processing, saving happens when ready.
    func commit() {
        if isProcessing {
            // Finish in the background; save as soon as it's done.
            onReadyCommit = true
            dismiss()
            return
        }
        save()
        dismiss()
    }

    /// Set when the user dismissed during processing.
    var onReadyCommit = false

    func discard() {
        pauseTimer()
        if let savedURL { try? FileManager.default.trashItem(at: savedURL, resultingItemURL: nil) }
        else if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
        dismiss()
    }

    /// Runs a long export (GIF, trim…) while keeping the thumbnail up.
    func runBusy(_ label: String, _ work: @escaping () async throws -> Void) {
        busy = true
        pauseTimer()
        model.exporting = label
        Task {
            do { try await work() } catch { Toast.error("\(label) failed: \(error.localizedDescription)") }
            busy = false
            model.exporting = nil
            commit()
        }
    }

    private func dismiss() {
        pauseTimer()
        guard isVisible else { onClose?(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            if Design.reduceMotion {
                animator().alphaValue = 0
            } else {
                animator().setFrame(restingFrame.offsetBy(dx: frame.width + 40, dy: 0), display: true)
            }
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
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.6).cgColor
        layer?.contents = image
        layer?.contentsGravity = .resizeAspectFill
        let overlay = NSHostingView(rootView: ThumbnailOverlay(model: panel.model, isVideo: isVideo))
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The SwiftUI overlay is decoration only; this view handles all input.
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

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
        guard let panel, !panel.isProcessing else { return }
        if let url = panel.save() { NSWorkspace.shared.open(url) }
        panel.commit()
    }

    override func scrollWheel(with event: NSEvent) {
        // Two-finger swipe dismisses (and saves), like the system thumbnail.
        swipeX += event.scrollingDeltaX
        if event.phase == .ended || event.momentumPhase == .began {
            if abs(swipeX) > 30 { panel?.commit() }
            swipeX = 0
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let panel, !panel.isProcessing else { return }
        panel.pauseTimer()
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        add("Open", #selector(open))
        add("Show in Finder", #selector(reveal))
        add("Copy", #selector(copyFile))
        if panel.isVideo {
            menu.addItem(.separator())
            add("Trim…", #selector(trim))
            add("Export GIF", #selector(exportGIF))
            let other: VideoFormat = panel.tempURL?.pathExtension == "mov" ? .mp4 : .mov
            add("Export as \(other.rawValue.uppercased())", #selector(remux))
        }
        menu.addItem(.separator())
        add("Delete", #selector(delete))
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        if panel.isVisible { panel.startTimer() }
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
        Toast.info("Copied")
        panel?.commit()
    }

    @objc private func trim() {
        guard let panel, let url = panel.save() else { return }
        panel.pauseTimer()
        TrimWindow.show(url) { [weak panel] range in
            guard let range else { panel?.commit(); return }
            panel?.runBusy("Trim") {
                try await VideoExport.trim(url, to: range)
                Toast.info("Trimmed", icon: "scissors", action: .reveal(url))
            }
        }
    }

    @objc private func exportGIF() {
        guard let panel, let url = panel.save() else { return }
        panel.runBusy("GIF") { [model = panel.model] in
            let gif = try await VideoExport.gif(from: url) { p in
                Task { @MainActor in model.progress = p }
            }
            Toast.info("Saved \(gif.lastPathComponent)", icon: "photo.on.rectangle", action: .reveal(gif))
        }
    }

    @objc private func remux() {
        guard let panel, let url = panel.save() else { return }
        let format: VideoFormat = url.pathExtension == "mov" ? .mp4 : .mov
        panel.runBusy("Export") {
            let out = try await VideoExport.remux(url, to: format)
            Toast.info("Saved \(out.lastPathComponent)", icon: "film", action: .reveal(out))
        }
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

/// Play badge, plus a progress ring while finishing or exporting.
private struct ThumbnailOverlay: View {
    @ObservedObject var model: ThumbnailModel
    let isVideo: Bool

    var body: some View {
        ZStack {
            if model.progress != nil || model.exporting != nil {
                Color.black.opacity(0.35)
                ZStack {
                    Circle().stroke(.white.opacity(0.25), lineWidth: 3)
                    if let p = model.progress, p > 0 {
                        Circle()
                            .trim(from: 0, to: p)
                            .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.15), value: p)
                    } else {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                }
                .frame(width: 28, height: 28)
            } else if isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4)
            }
        }
        .allowsHitTesting(false)
    }
}
