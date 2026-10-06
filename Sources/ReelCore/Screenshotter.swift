import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

public enum Screenshotter {
    public struct Shot: @unchecked Sendable {
        public let image: CGImage
        /// Pixels per point, so the PNG can carry the right DPI (144 on Retina).
        public let scale: CGFloat
    }

    public static func capture(
        _ target: CaptureTarget,
        options: CaptureOptions = CaptureOptions(),
        keepWindows: [CGWindowID] = []
    ) async throws -> Shot {
        var options = options
        options.systemAudio = false
        options.microphone = false
        let (filter, config) = try await StreamSetup.make(target: target, options: options, keepWindows: keepWindows)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return Shot(image: image, scale: CGFloat(filter.pointPixelScale))
    }

    public static func writePNG(_ shot: Shot, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ReelError.writeFailed(url)
        }
        let dpi = 72 * shot.scale
        let props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        CGImageDestinationAddImage(dest, shot.image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ReelError.writeFailed(url) }
    }
}
