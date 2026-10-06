import CoreGraphics
import Foundation

/// Decides when and where auto-zoom zooms. Clicks close together in time and
/// space form a group; each group eases in just before its first click, follows
/// the cursor while zoomed, and eases out after its last click.
public struct ZoomTimeline: Sendable {
    public struct Group: Equatable, Sendable {
        public var firstClick: Double
        public var lastClick: Double
        public var center: CGPoint
    }

    public static let groupGap = 2.5        // max seconds between clicks in a group
    public static let groupReach = 0.35     // max distance from group center, as a fraction of the frame
    public static let easeIn = 0.5
    public static let lead = 0.15           // fully zoomed this long before the first click
    public static let hold = 1.2            // stay zoomed after the last click
    public static let easeOut = 0.6

    public let frame: CGSize
    public let scale: Double
    public let groups: [Group]

    public init(clicks: [(t: Double, p: CGPoint)], frame: CGSize, scale: Double) {
        self.frame = frame
        self.scale = max(1, scale)
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
            let outStart = g.lastClick + Self.hold
            let outEnd = outStart + Self.easeOut
            let v: Double
            if t <= inStart || t >= outEnd { v = 0 }
            else if t < inEnd { v = smoothstep((t - inStart) / Self.easeIn) }
            else if t <= outStart { v = 1 }
            else { v = 1 - smoothstep((t - outStart) / Self.easeOut) }
            best = max(best, v)
        }
        return best
    }

    /// The group whose zoom window contains t, for choosing a focus before the
    /// cursor gets there.
    private func group(at t: Double) -> Group? {
        groups.last { t >= $0.firstClick - Self.lead - Self.easeIn && t <= $0.lastClick + Self.hold + Self.easeOut }
    }

    /// The visible rect (frame pixels, top-left origin) at t. `cursor` is a
    /// smoothed cursor position; while easing in we aim at the group's center.
    public func crop(at t: Double, cursor: CGPoint?) -> CGRect {
        let a = amount(at: t)
        guard a > 0.0001 else { return CGRect(origin: .zero, size: frame) }
        let z = 1 + (scale - 1) * a
        let w = frame.width / z, h = frame.height / z
        var focus = cursor ?? CGPoint(x: frame.width / 2, y: frame.height / 2)
        if let g = group(at: t), t < g.firstClick {
            let u = CGFloat(smoothstep((t - (g.firstClick - Self.lead - Self.easeIn)) / (Self.easeIn + Self.lead)))
            focus = CGPoint(x: g.center.x + (focus.x - g.center.x) * u * 0.5, y: g.center.y + (focus.y - g.center.y) * u * 0.5)
        }
        let x = min(max(focus.x - w / 2, 0), frame.width - w)
        let y = min(max(focus.y - h / 2, 0), frame.height - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

func smoothstep(_ x: Double) -> Double {
    let t = min(max(x, 0), 1)
    return t * t * (3 - 2 * t)
}
