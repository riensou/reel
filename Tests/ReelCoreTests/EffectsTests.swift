import AVFoundation
import CoreGraphics
import Testing
@testable import ReelCore

@Suite struct CursorTrackTests {
    /// A jittery left-to-right sweep with a jump, sampled at 60 Hz.
    private func samples() -> [(t: Double, p: CGPoint)] {
        (0..<120).map { i in
            let t = Double(i) / 60
            let jitter = CGFloat(i % 2 == 0 ? 3 : -3)
            let x: CGFloat = i < 60 ? CGFloat(i) * 5 : 900 // jump at 1s
            return (t, CGPoint(x: x, y: 200 + jitter))
        }
    }

    @Test func landsExactlyOnClicks() throws {
        let s = samples()
        let clickT = 1.5
        let track = CursorTrack(samples: s, clicks: [clickT])
        let p = try #require(track.position(at: clickT))
        #expect(abs(p.x - 900) < 0.5)
    }

    @Test func removesJitterAndGlidesOverJumps() throws {
        let track = CursorTrack(samples: samples())
        // Jitter of ±3 px should be damped well below that.
        let ys = stride(from: 0.2, to: 0.9, by: 1.0 / 60).compactMap { track.position(at: $0)?.y }
        #expect((ys.max()! - ys.min()!) < 2)
        // Shortly after the jump the cursor is on its way, not teleported.
        let mid = try #require(track.position(at: 1.05)).x
        #expect(mid > 300 && mid < 880)
        // …and it arrives.
        #expect(abs(try #require(track.position(at: 1.9)).x - 900) < 2)
    }

    @Test func emptyTrack() {
        #expect(CursorTrack(samples: []).position(at: 1) == nil)
    }
}

@Suite struct ZoomTimelineTests {
    let frame = CGSize(width: 2000, height: 1000)

    @Test func groupsNearbyClicksOnly() {
        let z = ZoomTimeline(clicks: [
            (1.0, CGPoint(x: 100, y: 100)),
            (2.0, CGPoint(x: 150, y: 120)),   // near in time + space → same group
            (3.0, CGPoint(x: 1900, y: 900)),  // far away → new group
            (9.0, CGPoint(x: 1900, y: 900)),  // long gap → new group
        ], frame: frame, scale: 2)
        #expect(z.groups.count == 3)
        #expect(z.groups[0].firstClick == 1 && z.groups[0].lastClick == 2)
    }

    @Test func easesInBeforeAndOutAfter() {
        let z = ZoomTimeline(clicks: [(2.0, CGPoint(x: 1000, y: 500))], frame: frame, scale: 2)
        #expect(z.amount(at: 0.5) == 0)
        #expect(z.amount(at: 2.0 - ZoomTimeline.lead) == 1)           // fully in by the click
        #expect(z.amount(at: 2.0 + ZoomTimeline.hold) == 1)
        let mid = z.amount(at: 2.0 + ZoomTimeline.hold + ZoomTimeline.easeOut / 2)
        #expect(mid > 0.3 && mid < 0.7)
        #expect(z.amount(at: 10) == 0)
    }

    @Test func cropStaysInsideFrame() {
        let z = ZoomTimeline(clicks: [(1.0, CGPoint(x: 5, y: 5))], frame: frame, scale: 2)
        let r = z.crop(at: 1.0, cursor: CGPoint(x: 0, y: 0))
        #expect(r.size == CGSize(width: 1000, height: 500))
        #expect(r.minX == 0 && r.minY == 0)
        #expect(z.crop(at: 20, cursor: nil) == CGRect(origin: .zero, size: frame))
    }
}

@Suite struct VideoExportTests {
    @Test func gifTrimAndRemux() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clip = dir.appending(path: "clip.mp4")
        var job = Finisher.Job(segments: [try await makeTestClip(in: dir, seconds: 2)], output: clip)
        job.mergeAudio = true
        try await Finisher.run(job)

        let gif = try await VideoExport.gif(from: clip, fps: 10)
        let src = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        #expect(CGImageSourceGetCount(src) >= 18)

        let mov = try await VideoExport.remux(clip, to: .mov)
        #expect(mov.pathExtension == "mov")

        try await VideoExport.trim(clip, to: CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                         duration: CMTime(seconds: 1, preferredTimescale: 600)))
        let d = try await AVURLAsset(url: clip).load(.duration).seconds
        #expect(d < 1.6)
    }
}
