import CoreGraphics
import Foundation

/// Decides when auto-zoom is zoomed in. Clicks close together in time and space
/// form a group; each group eases in just before its first click and eases out
/// a little after its last one. `CameraPath` decides where the camera points.
public struct ZoomTimeline: Sendable {
    public struct Group: Equatable, Sendable {
        public var firstClick: Double
        public var lastClick: Double
        public var center: CGPoint
    }

    public static let groupGap = 3.0        // max seconds between clicks in a group
    public static let groupReach = 0.45     // max distance from group center, as a fraction of the frame
    public static let easeIn = 0.7
    public static let lead = 0.1            // fully zoomed this long before the first click
    public static let hold = 1.6            // stay zoomed after the last click
    public static let easeOut = 0.9

    public let frame: CGSize
    public let scale: Double
    public let groups: [Group]
    /// Recording length; zoom-outs are pulled earlier so videos end on the full frame.
    public let duration: Double

    public init(clicks: [(t: Double, p: CGPoint)], frame: CGSize, scale: Double, duration: Double = .infinity) {
        self.frame = frame
        self.scale = max(1, scale)
        self.duration = duration
        let reach = Self.groupReach * Double(max(frame.width, frame.height))
        var groups: [Group] = []
        var members: [CGPoint] = []
        for click in clicks.sorted(by: { $0.t < $1.t }) {
            if var g = groups.last,
               click.t - g.lastClick <= Self.groupGap,
               hypot(click.p.x - g.center.x, click.p.y - g.center.y) <= reach {
                members.append(click.p)
                g.lastClick = click.t
                g.center = CGPoint(x: members.map(\.x).reduce(0, +) / CGFloat(members.count),
                                   y: members.map(\.y).reduce(0, +) / CGFloat(members.count))
                groups[groups.count - 1] = g
            } else {
                members = [click.p]
                groups.append(Group(firstClick: click.t, lastClick: click.t, center: click.p))
            }
        }
        self.groups = groups
    }

    /// Zoom envelope 0…1 at time t (max over overlapping groups).
    public func amount(at t: Double) -> Double {
        var best = 0.0
        for g in groups {
            let inEnd = g.firstClick - Self.lead
            let inStart = inEnd - Self.easeIn
            // Near the end of the recording, hold and ease out faster so the
            // video lands on the full frame.
            let outStart = min(g.lastClick + Self.hold, max(g.lastClick + 0.3, duration - Self.easeOut))
            let outDuration = max(0.3, min(Self.easeOut, duration - outStart))
            let outEnd = outStart + outDuration
            let v: Double
            if t <= inStart || t >= outEnd { v = 0 }
            else if t < inEnd { v = easeInOut((t - inStart) / Self.easeIn) }
            else if t <= outStart { v = 1 }
            else { v = 1 - easeInOut((t - outStart) / outDuration) }
            best = max(best, v)
        }
        return best
    }

    /// Zoom factor (1 = full frame) at t.
    public func zoom(at t: Double) -> Double { 1 + (scale - 1) * amount(at: t) }

    /// The group whose zoom window contains t.
    func group(at t: Double) -> Group? {
        groups.last { t >= $0.firstClick - Self.lead - Self.easeIn && t <= $0.lastClick + Self.hold + Self.easeOut }
    }
}

/// Where the zoomed camera looks, precomputed at 60 Hz.
///
/// Like a camera operator: fly toward each click as it happens, then hold still
/// while the cursor stays in the middle of the shot, and only pan (smoothly)
/// when it drifts toward an edge. Zooming out drifts back to the full frame.
public struct CameraPath: Sendable {
    private let start: Double
    private let step = 1.0 / 60
    private let rects: [CGRect]
    public let frame: CGSize

    /// - Parameters:
    ///   - cursor: smoothed cursor position over time (frame pixels, top-left origin).
    ///   - deadzone: fraction of the visible area the cursor can roam before the camera pans.
    public init(zoom: ZoomTimeline, clicks: [(t: Double, p: CGPoint)], duration: Double,
                cursor: (Double) -> CGPoint?, deadzone: CGFloat = 0.5, stiffness: Double = 9) {
        frame = zoom.frame
        start = 0
        let W = frame.width, H = frame.height
        let count = max(1, Int((duration / step).rounded(.up)) + 1)
        let clicks = clicks.sorted { $0.t < $1.t }
        var out: [CGRect] = []
        out.reserveCapacity(count)

        var center = CGPoint(x: W / 2, y: H / 2)
        var vel = CGVector.zero
        var target = center
        var nextClick = 0
        let w = stiffness
        // Aim for where the camera must be at *full* zoom; clamping to the
        // current (growing) zoom would make the target slide during zoom-in.
        let fullHW = W / (2 * CGFloat(zoom.scale)), fullHH = H / (2 * CGFloat(zoom.scale))

        for i in 0..<count {
            let t = Double(i) * step
            let z = CGFloat(zoom.zoom(at: t))
            let hw = W / (2 * z), hh = H / (2 * z)

            if z <= 1.0001 {
                target = CGPoint(x: W / 2, y: H / 2)
            } else {
                // Aim at upcoming clicks as the camera arrives, so it frames
                // the click by the time it happens.
                while nextClick < clicks.count, clicks[nextClick].t < t - 0.05 { nextClick += 1 }
                if nextClick < clicks.count, clicks[nextClick].t - t < ZoomTimeline.easeIn + ZoomTimeline.lead {
                    target = clicks[nextClick].p
                } else if let c = cursor(t) {
                    // Pan only when the cursor leaves the deadzone around the current target.
                    let dx = fullHW * deadzone, dy = fullHH * deadzone
                    if c.x > target.x + dx { target.x = c.x - dx }
                    if c.x < target.x - dx { target.x = c.x + dx }
                    if c.y > target.y + dy { target.y = c.y - dy }
                    if c.y < target.y - dy { target.y = c.y + dy }
                }
            }
            let clampedTarget = z <= 1.0001
                ? target
                : CGPoint(x: min(max(target.x, fullHW), W - fullHW), y: min(max(target.y, fullHH), H - fullHH))

            // Critically damped spring toward the target.
            let ax = w * w * (clampedTarget.x - center.x) - 2 * w * vel.dx
            let ay = w * w * (clampedTarget.y - center.y) - 2 * w * vel.dy
            vel.dx += ax * step
            vel.dy += ay * step
            center.x += vel.dx * step
            center.y += vel.dy * step

            let cx = min(max(center.x, hw), W - hw)
            let cy = min(max(center.y, hh), H - hh)
            out.append(CGRect(x: cx - hw, y: cy - hh, width: hw * 2, height: hh * 2))
        }
        rects = out
    }

    /// Visible rect (frame pixels, top-left origin) at t.
    public func crop(at t: Double) -> CGRect {
        guard !rects.isEmpty else { return CGRect(origin: .zero, size: frame) }
        let f = (t - start) / step
        if f <= 0 { return rects[0] }
        let i = Int(f)
        if i >= rects.count - 1 { return rects[rects.count - 1] }
        let a = rects[i], b = rects[i + 1], u = CGFloat(f - Double(i))
        return CGRect(x: a.minX + (b.minX - a.minX) * u, y: a.minY + (b.minY - a.minY) * u,
                      width: a.width + (b.width - a.width) * u, height: a.height + (b.height - a.height) * u)
    }
}

func smoothstep(_ x: Double) -> Double {
    let t = min(max(x, 0), 1)
    return t * t * (3 - 2 * t)
}

/// Cubic ease-in-out: gentler start and landing than smoothstep.
func easeInOut(_ x: Double) -> Double {
    let t = min(max(x, 0), 1)
    return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
}
