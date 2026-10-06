import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Post-save tools offered on the thumbnail: trim, change container, GIF.
public enum VideoExport {
    /// Cuts `url` to `range` in place, without re-encoding.
    public static func trim(_ url: URL, to range: CMTimeRange) async throws {
        let tmp = url.deletingLastPathComponent().appending(path: ".reel-trim-\(UUID().uuidString).\(url.pathExtension)")
        try await passthrough(url, to: tmp, range: range)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    /// Writes a copy of `url` in the other container (mp4 ⇄ mov), next to it.
    public static func remux(_ url: URL, to format: VideoFormat) async throws -> URL {
        var out = url.deletingPathExtension().appendingPathExtension(format.rawValue)
        var n = 2
        while FileManager.default.fileExists(atPath: out.path) {
            out = url.deletingLastPathComponent().appending(path: "\(url.deletingPathExtension().lastPathComponent) (\(n)).\(format.rawValue)")
            n += 1
        }
        try await passthrough(url, to: out, range: nil)
        return out
    }

    private static func passthrough(_ url: URL, to out: URL, range: CMTimeRange?) async throws {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ReelError.writeFailed(out)
        }
        if let range { session.timeRange = range }
        try await session.export(to: out, as: out.pathExtension == "mov" ? .mov : .mp4)
    }

    /// A looping GIF next to the video. 15 fps, ≤960 px wide by default.
    public static func gif(
        from url: URL, fps: Double = 15, maxWidth: CGFloat = 960,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let out = url.deletingPathExtension().appendingPathExtension("gif")
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let count = max(1, Int(duration * fps))
        let times = (0..<count).map { CMTime(seconds: Double($0) / fps, preferredTimescale: 600) }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4)
        let tol = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol

        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw ReelError.writeFailed(out)
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProps = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps],
        ] as CFDictionary

        var done = 0
        for await result in gen.images(for: times) {
            if let image = try? result.image {
                CGImageDestinationAddImage(dest, image, frameProps)
            }
            done += 1
            progress(Double(done) / Double(count))
        }
        guard CGImageDestinationFinalize(dest) else { throw ReelError.writeFailed(out) }
        return out
    }
}
