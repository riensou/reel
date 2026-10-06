import CoreGraphics
import Foundation

/// A smoothed cursor path. Raw 60 Hz mouse samples are fed through a critically
/// damped spring (no overshoot), which removes jitter and turns jumps into
/// glides. Around clicks the path blends back to the raw position so the
/// cursor always lands exactly where the click happened.
public struct CursorTrack: Sendable {
    private let start: Double
    private let step: Double
    private let points: [CGPoint]

    /// - Parameters:
    ///   - stiffness: spring angular frequency (rad/s). Higher = snappier.
    ///   - clickSnap: seconds around each click over which the raw position takes over.
    public init(samples: [(t: Double, p: CGPoint)], clicks: [Double] = [], stiffness: Double = 16, clickSnap: Double = 0.12) {
        let rate = 120.0
        step = 1 / rate
        guard let first = samples.first, let last = samples.last else {
            start = 0
            points = []
            return
        }
        start = first.t
        let count = max(1, Int(((last.t - first.t) * rate).rounded(.up)) + 1)
        var out: [CGPoint] = []
        out.reserveCapacity(count)

        var pos = first.p
        var vel = CGVector.zero
        var j = 0
        let clicks = clicks.sorted()
        var c = 0
        let w = stiffness
        for i in 0..<count {
            let t = first.t + Double(i) * step
            while j + 1 < samples.count, samples[j + 1].t <= t { j += 1 }
            let target = Self.interpolate(samples, j, t)

            // Semi-implicit Euler on x'' = w²(target − x) − 2w·x'
            let ax = w * w * (target.x - pos.x) - 2 * w * vel.dx
            let ay = w * w * (target.y - pos.y) - 2 * w * vel.dy
            vel.dx += ax * step
            vel.dy += ay * step
            pos.x += vel.dx * step
            pos.y += vel.dy * step

            while c + 1 < clicks.count, clicks[c + 1] <= t { c += 1 }
            var snap = 0.0
            for k in [c, c + 1] where k < clicks.count {
                snap = max(snap, 1 - abs(t - clicks[k]) / clickSnap)
            }
            if snap > 0 {
                let s = CGFloat(snap * snap * (3 - 2 * snap)) // smoothstep
                out.append(CGPoint(x: pos.x + (target.x - pos.x) * s, y: pos.y + (target.y - pos.y) * s))
            } else {
                out.append(pos)
            }
        }
        points = out
    }

    public var isEmpty: Bool { points.isEmpty }

    public func position(at t: Double) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let f = (t - start) / step
        if f <= 0 { return points[0] }
        let i = Int(f)
        if i >= points.count - 1 { return points[points.count - 1] }
        let a = points[i], b = points[i + 1], u = CGFloat(f - Double(i))
        return CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)
    }

    private static func interpolate(_ s: [(t: Double, p: CGPoint)], _ j: Int, _ t: Double) -> CGPoint {
        guard j + 1 < s.count, t > s[j].t else { return s[j].p }
        let a = s[j], b = s[j + 1]
        let u = CGFloat((t - a.t) / max(b.t - a.t, 1e-6))
        return CGPoint(x: a.p.x + (b.p.x - a.p.x) * u, y: a.p.y + (b.p.y - a.p.y) * u)
    }
}
