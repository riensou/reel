import CoreGraphics
import Foundation

/// Cursor movement and clicks captured alongside a recording, used by auto-zoom
/// and the smoothed cursor. Positions are in captured-frame pixels with a
/// top-left origin; times are seconds of recorded (non-paused) time.
public struct EventLog: Codable, Sendable {
    public struct Sample: Codable, Sendable {
        public var t: Double
        public var p: CGPoint
        public var cursor: Int
        public init(t: Double, p: CGPoint, cursor: Int) {
            self.t = t
            self.p = p
            self.cursor = cursor
        }
    }

    public struct Click: Codable, Sendable {
        public var t: Double
        public var p: CGPoint
        public init(t: Double, p: CGPoint) {
            self.t = t
            self.p = p
        }
    }

    /// A cursor image as PNG, with its hotspot, both in points.
    public struct CursorImage: Codable, Sendable {
        public var png: Data
        public var size: CGSize
        public var hotspot: CGPoint
        public init(png: Data, size: CGSize, hotspot: CGPoint) {
            self.png = png
            self.size = size
            self.hotspot = hotspot
        }
    }

    public var frameSize: CGSize
    /// Captured pixels per point.
    public var scale: CGFloat
    public var samples: [Sample] = []
    public var clicks: [Click] = []
    public var cursors: [Int: CursorImage] = [:]

    public init(frameSize: CGSize, scale: CGFloat) {
        self.frameSize = frameSize
        self.scale = scale
    }
}
