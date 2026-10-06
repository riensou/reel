import CoreGraphics
import CoreImage
import CoreMedia
import Foundation

/// Builds the per-frame effect for auto-zoom and the smoothed cursor from an
/// `EventLog`. Per frame: click ripples, then the cursor, then the zoom crop —
/// so ripples and cursor zoom with the content.
public enum DemoEffects {
    /// Clicks this close to the end are almost always the click that stopped
    /// the recording (menu bar, hotkey), not part of the demo.
    static let ignoreTail = 0.75
    static let rippleDuration = 0.5

    /// Clicks worth reacting to: inside the frame and not the closing click.
    static func demoClicks(_ log: EventLog) -> [EventLog.Click] {
        let bounds = CGRect(origin: .zero, size: log.frameSize)
        return log.clicks.filter { bounds.contains($0.p) && $0.t < log.duration - ignoreTail }
    }

    public static func make(log: EventLog, autoZoom: Bool, zoomScale: Double, smoothCursor: Bool) -> Finisher.FrameEffect? {
        guard autoZoom || smoothCursor, !log.samples.isEmpty else { return nil }
        let raw = log.samples.map { (t: $0.t, p: $0.p) }
        let clicks = demoClicks(log)
        let clickTimes = clicks.map(\.t)
        let H = log.frameSize.height
        let W = log.frameSize.width
        let scale = log.scale

        let cursorTrack = CursorTrack(samples: raw, clicks: clickTimes, stiffness: 18)
        let duration = max(log.duration, raw.last?.t ?? 0)
        let camera: CameraPath? = autoZoom ? CameraPath(
            zoom: ZoomTimeline(clicks: clicks.map { (t: $0.t, p: $0.p) }, frame: log.frameSize, scale: zoomScale, duration: duration),
            clicks: clicks.map { (t: $0.t, p: $0.p) },
            duration: duration,
            cursor: { cursorTrack.position(at: $0) }
        ) : nil

        let images = Box(log.cursors.compactMapValues { c -> (CIImage, EventLog.CursorImage)? in
            guard let img = CIImage(data: c.png) else { return nil }
            // Normalize to cursor size × capture scale (the PNG may be any resolution).
            let target = CGSize(width: c.size.width * scale, height: c.size.height * scale)
            let sx = target.width / max(img.extent.width, 1), sy = target.height / max(img.extent.height, 1)
            return (img.transformed(by: CGAffineTransform(scaleX: sx, y: sy)), c)
        })
        let ripple = Box(rippleImage(diameter: 64 * scale))
        let samples = log.samples

        // What the effect looks like at t — used to skip frames that would be
        // identical to the previous one (encoding is the slow part).
        let signature: @Sendable (Double) -> [Double] = { t in
            func q(_ v: CGFloat) -> Double { (Double(v) * 4).rounded() / 4 }
            var sig: [Double] = []
            if smoothCursor, let p = cursorTrack.position(at: t) {
                let nearest = clickTimes.lazy.map { abs($0 - t) }.min() ?? .infinity
                sig += [q(p.x), q(p.y), Double(cursorID(at: t, in: samples) ?? -1), nearest < 0.15 ? t : -1]
            }
            if let camera {
                let r = camera.crop(at: t)
                sig += [q(r.minX), q(r.minY), q(r.width)]
            }
            // Ripples animate every frame while active.
            if clickTimes.contains(where: { t >= $0 && t < $0 + rippleDuration }) { sig.append(t) }
            return sig
        }

        let render: @Sendable (CIImage, CMTime) -> CIImage = { image, time in
            let t = time.seconds
            var out = image
            // Top-left frame coordinates → Core Image's bottom-left.
            func ci(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: H - p.y) }

            // Click ripples: a ring that expands and fades where you clicked.
            if let ring = ripple.value {
                for c in clicks where t >= c.t && t < c.t + rippleDuration {
                    let u = (t - c.t) / rippleDuration
                    let s = 0.35 + 0.65 * (1 - pow(1 - u, 3))
                    let alpha = 0.9 * (1 - u)
                    let at = ci(c.p)
                    let r = ring.extent.width / 2
                    let placed = ring
                        .transformed(by: CGAffineTransform(translationX: -r, y: -r))
                        .transformed(by: CGAffineTransform(scaleX: s, y: s))
                        .transformed(by: CGAffineTransform(translationX: at.x, y: at.y))
                        .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
                    out = placed.composited(over: out)
                }
            }

            if smoothCursor, let p = cursorTrack.position(at: t),
               let (cursor, info) = cursorID(at: t, in: samples).flatMap({ images.value[$0] }) ?? images.value.values.first {
                // Press-down: briefly shrink around the hotspot.
                let nearest = clickTimes.lazy.map { abs($0 - t) }.min() ?? .infinity
                let press = nearest < 0.15 ? 1 - 0.15 * (1 - nearest / 0.15) : 1
                let hx = info.hotspot.x * scale, hy = info.hotspot.y * scale
                let ch = cursor.extent.height
                let at = ci(p)
                let placed = cursor
                    .transformed(by: CGAffineTransform(translationX: -hx, y: -(ch - hy)))
                    .transformed(by: CGAffineTransform(scaleX: press, y: press))
                    .transformed(by: CGAffineTransform(translationX: at.x, y: at.y))
                out = placed.composited(over: out)
            }

            if let camera {
                let r = camera.crop(at: t)
                if r.width < W - 0.5 {
                    let k = W / r.width
                    out = out
                        .transformed(by: CGAffineTransform(translationX: -r.minX, y: -(H - r.maxY)))
                        .transformed(by: CGAffineTransform(scaleX: k, y: k))
                        .cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
                }
            }
            return out
        }
        return Finisher.FrameEffect(render: render, signature: signature)
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

    /// A soft white ring with a faint dark edge so it reads on any background.
    static func rippleImage(diameter: CGFloat) -> CIImage? {
        let size = Int(diameter.rounded(.up)) + 8
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 4, y: 4, width: diameter, height: diameter)
        let line = diameter * 0.07
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.18))
        ctx.fillEllipse(in: rect.insetBy(dx: line, dy: line))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.25))
        ctx.setLineWidth(line + 2)
        ctx.strokeEllipse(in: rect.insetBy(dx: line / 2, dy: line / 2))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
        ctx.setLineWidth(line)
        ctx.strokeEllipse(in: rect.insetBy(dx: line / 2, dy: line / 2))
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }
}

/// CIImage is immutable and thread-safe; this just tells the compiler so.
private struct Box<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
