import AppKit
import QuartzCore
import ReelCore

/// A thin outline just outside the recorded area, so you can see what's being
/// captured. It sits outside the capture rect (and reel's windows are excluded
/// from capture anyway), so it never appears in the video.
@MainActor
final class RecordingBorder {
    private let target: CaptureTarget
    private var panel: NSPanel?
    private var shape: CAShapeLayer?
    private var follow: Timer?
    private let gap: CGFloat = 3
    private let margin: CGFloat = 12

    init(target: CaptureTarget) {
        self.target = target
    }

    func show() {
        guard let rect = CaptureGeometry.nsRect(for: target) else { return }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = NSView()
        view.wantsLayer = true
        let shape = CAShapeLayer()
        shape.fillColor = nil
        shape.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        shape.lineWidth = 1.5
        shape.shadowColor = NSColor.black.cgColor
        shape.shadowOpacity = 0.45
        shape.shadowRadius = 3
        shape.shadowOffset = .zero
        view.layer?.addSublayer(shape)
        panel.contentView = view
        self.panel = panel
        self.shape = shape
        place(around: rect)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }

        if case .window = target {
            follow = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let r = CaptureGeometry.nsRect(for: self.target) else { return }
                    self.place(around: r)
                }
            }
        }
    }

    func hide() {
        follow?.invalidate()
        follow = nil
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 },
                                            completionHandler: { panel.orderOut(nil) })
    }

    private func place(around rect: NSRect) {
        guard let panel, let shape else { return }
        let frame = rect.insetBy(dx: -(gap + margin), dy: -(gap + margin))
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        let outline = NSRect(x: margin, y: margin, width: rect.width + gap * 2, height: rect.height + gap * 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = NSRect(origin: .zero, size: frame.size)
        shape.path = CGPath(roundedRect: outline, cornerWidth: 4, cornerHeight: 4, transform: nil)
        CATransaction.commit()
    }
}
