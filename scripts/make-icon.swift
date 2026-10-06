// Draws reel's app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
//
// A graphite squircle, a dashed selection rectangle, and a red record dot.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body with ~185/1024 corner radius.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225
    let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(squircle)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Graphite gradient body.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(calibratedRed: 0.20, green: 0.21, blue: 0.24, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.10, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    ctx.restoreGState()

    // Hairline edge.
    ctx.addPath(squircle)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
    ctx.setLineWidth(max(1, s * 0.004))
    ctx.strokePath()

    // Dashed selection rectangle.
    let sel = body.insetBy(dx: body.width * 0.2, dy: body.height * 0.25)
    let selPath = CGPath(roundedRect: sel, cornerWidth: s * 0.02, cornerHeight: s * 0.02, transform: nil)
    ctx.addPath(selPath)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
    ctx.setLineWidth(s * 0.022)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [s * 0.045, s * 0.04])
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])

    // Corner handles.
    let h = s * 0.034
    for p in [CGPoint(x: sel.minX, y: sel.minY), CGPoint(x: sel.maxX, y: sel.minY),
              CGPoint(x: sel.minX, y: sel.maxY), CGPoint(x: sel.maxX, y: sel.maxY)] {
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - h / 2, y: p.y - h / 2, width: h, height: h))
    }

    // Record dot with a soft glow.
    let r = s * 0.11
    let c = CGPoint(x: sel.midX, y: sel.midY)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.05, color: NSColor.systemRed.withAlphaComponent(0.6).cgColor)
    ctx.setFillColor(NSColor(calibratedRed: 1.0, green: 0.27, blue: 0.23, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try draw(size).write(to: iconset.appending(path: "icon_\(size)x\(size).png"))
    try draw(size * 2).write(to: iconset.appending(path: "icon_\(size)x\(size)@2x.png"))
}
let out = root.appending(path: "Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
try draw(1024).write(to: root.appending(path: "Resources/AppIcon.png"))
print(p.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
