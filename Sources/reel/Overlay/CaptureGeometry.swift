import AppKit
import ReelCore

/// Converting between capture targets and on-screen rects.
///
/// "CG global" = points, top-left origin of the primary display (what
/// CGDisplayBounds and the window list use). "NS global" = points, bottom-left
/// origin (what NSWindow frames use).
enum CaptureGeometry {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// The captured area in CG global coordinates, right now.
    static func cgRect(for target: CaptureTarget) -> CGRect? {
        switch target {
        case .display(let id):
            return CGDisplayBounds(id)
        case .region(let id, let r):
            let d = CGDisplayBounds(id)
            return r.offsetBy(dx: d.minX, dy: d.minY)
        case .window(let id):
            guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary
            else { return nil }
            return CGRect(dictionaryRepresentation: dict)
        }
    }

    static func nsRect(fromCG r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func nsRect(for target: CaptureTarget) -> NSRect? {
        cgRect(for: target).map(nsRect(fromCG:))
    }

    /// The mouse location in CG global coordinates.
    static var mouseCG: CGPoint {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    static func screen(for target: CaptureTarget) -> NSScreen? {
        guard let r = nsRect(for: target) else { return NSScreen.main }
        let center = NSPoint(x: r.midX, y: r.midY)
        return NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? NSScreen.main
    }
}
