import AppKit
import ReelCore

/// Samples the cursor (position + image) at 60 Hz and logs clicks while
/// recording, for auto-zoom and the smoothed cursor. Mouse monitoring needs no
/// extra permission.
@MainActor
final class EventRecorder {
    private let target: CaptureTarget
    private let clock: () -> (t: Double, active: Bool)
    private var log: EventLog
    private var timer: Timer?
    private var monitors: [Any] = []
    private var cursorIDs: [String: Int] = [:]
    private var currentCursor = 0
    private var tick = 0

    init(target: CaptureTarget, frameSize: CGSize, scale: CGFloat, clock: @escaping () -> (t: Double, active: Bool)) {
        self.target = target
        self.clock = clock
        log = EventLog(frameSize: frameSize, scale: scale)
    }

    func start() {
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let onClick: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.click() }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: onClick) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in onClick(e); return e }) {
            monitors.append(l)
        }
    }

    func stop() -> EventLog {
        timer?.invalidate()
        timer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        return log
    }

    private func framePoint() -> CGPoint? {
        guard let origin = CaptureGeometry.cgRect(for: target)?.origin else { return nil }
        let m = CaptureGeometry.mouseCG
        return CGPoint(x: (m.x - origin.x) * log.scale, y: (m.y - origin.y) * log.scale)
    }

    private func sample() {
        let (t, active) = clock()
        guard active, let p = framePoint() else { return }
        if tick % 6 == 0 { updateCursorImage() }
        tick += 1
        log.samples.append(EventLog.Sample(t: t, p: p, cursor: currentCursor))
    }

    private func click() {
        let (t, active) = clock()
        guard active, let p = framePoint() else { return }
        log.clicks.append(EventLog.Click(t: t, p: p))
    }

    /// Cursor images change rarely; identify them cheaply by size + hotspot and
    /// only encode a PNG the first time each one appears.
    private func updateCursorImage() {
        guard let cursor = NSCursor.currentSystem else { return }
        let size = cursor.image.size
        let hs = cursor.hotSpot
        let key = "\(Int(size.width))x\(Int(size.height))@\(Int(hs.x)),\(Int(hs.y))"
        if let id = cursorIDs[key] {
            currentCursor = id
            return
        }
        // Keep the sharpest representation (cursor images carry 1x and 2x).
        guard let tiff = cursor.image.tiffRepresentation,
              let rep = NSBitmapImageRep.imageReps(with: tiff)
                .compactMap({ $0 as? NSBitmapImageRep })
                .max(by: { $0.pixelsWide < $1.pixelsWide }),
              let png = rep.representation(using: .png, properties: [:])
        else { return }
        let id = cursorIDs.count
        cursorIDs[key] = id
        log.cursors[id] = EventLog.CursorImage(png: png, size: size, hotspot: hs)
        currentCursor = id
    }
}
