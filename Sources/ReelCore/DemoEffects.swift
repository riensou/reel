import CoreImage
import Foundation

/// Builds the per-frame effect for auto-zoom and the smoothed cursor from an
/// `EventLog`. The cursor is drawn first so it zooms with the content.
public enum DemoEffects {
    public static func make(log: EventLog, autoZoom: Bool, zoomScale: Double, smoothCursor: Bool) -> Finisher.FrameEffect? {
        guard autoZoom || smoothCursor, !log.samples.isEmpty else { return nil }
        let raw = log.samples.map { (t: $0.t, p: $0.p) }
        let clickTimes = log.clicks.map(\.t)
        let H = log.frameSize.height
        let W = log.frameSize.width
        let scale = log.scale

        // The visible cursor glides; the camera follows a much lazier path.
        let cursorTrack = CursorTrack(samples: raw, clicks: clickTimes, stiffness: 18)
        let cameraTrack = CursorTrack(samples: raw, stiffness: 4)
        let zoom = autoZoom
            ? ZoomTimeline(clicks: log.clicks.map { (t: $0.t, p: $0.p) }, frame: log.frameSize, scale: zoomScale)
            : nil

        let images = SendableBox(log.cursors.compactMapValues { c -> (CIImage, EventLog.CursorImage)? in
            guard let img = CIImage(data: c.png) else { return nil }
            // Normalize to cursor size × capture scale (PNG may be any resolution).
            let target = CGSize(width: c.size.width * scale, height: c.size.height * scale)
            let sx = target.width / max(img.extent.width, 1), sy = target.height / max(img.extent.height, 1)
            return (img.transformed(by: CGAffineTransform(scaleX: sx, y: sy)), c)
        })
        let samples = log.samples
        let clicks = clickTimes

        return { image, time in
            let t = time.seconds
            var out = image

            if smoothCursor, let p = cursorTrack.position(at: t), let id = cursorID(at: t, in: samples),
               let (cursor, info) = images.value[id] {
                // Press-down: briefly shrink around the hotspot.
                let nearest = clicks.map { abs($0 - t) }.min() ?? .infinity
                let press = nearest < 0.15 ? 1 - 0.15 * (1 - nearest / 0.15) : 1
                let hx = info.hotspot.x * scale, hy = info.hotspot.y * scale
                let ch = cursor.extent.height
                // Top-left frame coords → Core Image bottom-left coords.
                let origin = CGPoint(x: p.x - hx, y: H - p.y - (ch - hy))
                let placed = cursor
                    .transformed(by: CGAffineTransform(translationX: -hx, y: -(ch - hy)))
                    .transformed(by: CGAffineTransform(scaleX: press, y: press))
                    .transformed(by: CGAffineTransform(translationX: origin.x + hx, y: origin.y + (ch - hy)))
                out = placed.composited(over: out)
            }

            if let zoom {
                let r = zoom.crop(at: t, cursor: cameraTrack.position(at: t))
                if r.width < W - 0.5 {
                    let ciY = H - r.maxY
                    let k = W / r.width
                    out = out
                        .transformed(by: CGAffineTransform(translationX: -r.minX, y: -ciY))
                        .transformed(by: CGAffineTransform(scaleX: k, y: k))
                        .cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
                }
            }
            return out
        }
    }

    private static func cursorID(at t: Double, in samples: [EventLog.Sample]) -> Int? {
        var lo = 0, hi = samples.count - 1
        guard hi >= 0 else { return nil }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if samples[mid].t <= t { lo = mid } else { hi = mid - 1 }
        }
        return samples[lo].cursor
    }
}

/// CIImage is immutable and thread-safe; this just tells the compiler so.
private struct SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
