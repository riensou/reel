#if DEBUG
import AVFoundation
import AppKit
import ReelCore

/// End-to-end checks of the interactive flows, driven through the real UI code
/// (`reel --self-test <dir>`). Mouse/keyboard events are synthesized into reel's
/// own windows; recordings are checked by inspecting the files they produce.
/// Uses an in-memory config, so the user's config file is never touched.
@MainActor
final class SelfTest {
    private let app: AppDelegate
    private let outDir: URL
    private var failures = 0

    init(app: AppDelegate, outDir: URL) {
        self.app = app
        self.outDir = outDir
    }

    func run(only: String? = nil) async -> Bool {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let savedSession = app.state.session
        defer { app.state.session = savedSession }
        var config = Config()
        config.saveDirectory = outDir.path
        config.thumbnail = false
        app.state.overrideConfig(config)

        if only == "toolbar" {
            await regionPicker()
            await toolbarRegion()
        } else if only == "trim" {
            await trimFromThumbnail()
        } else if only == "pause" {
            for _ in 0..<5 { await pauseResume() }
        } else {
            await regionPicker()
            await toolbarRegion()
            await windowPicker()
            await windowCapture()
            await countdown()
            await border()
            await pauseResume()
            await cancel()
            await systemStop()
            await systemStopUnattended()
            await trimWindowCancel()
            await trimFromThumbnail()
        }

        app.state.reloadConfig()
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0
    }

    /// Long recording with effects on: memory over time, then finishing time.
    func soak(minutes: Double) async {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var config = Config()
        config.saveDirectory = outDir.path
        config.thumbnail = false
        config.autoZoom = true
        config.smoothCursor = true
        app.state.overrideConfig(config)
        let saved = app.state.session
        app.state.session.systemAudio = true
        defer { app.state.session = saved; app.state.reloadConfig() }

        let session = RecordingSession(state: app.state, target: .display(screen.displayID), thumbnails: app.thumbnails, webcam: app.webcam)
        await session.start()
        let steps = Int(minutes * 2)
        for i in 1...steps {
            await wait(30)
            print(String(format: "t=%4.1fmin  memory %.0f MB", Double(i) / 2, Self.residentMB()))
        }
        let stopAt = Date()
        session.stop()
        for _ in 0..<1800 {
            await wait(1)
            if let f = ((try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? []).first(where: { $0.hasSuffix(".mp4") }) {
                let url = outDir.appending(path: f)
                let d = await duration(url)
                let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int ?? 0) / 1_048_576
                print(String(format: "finished in %.1fs after stop; video %.1fs, %d MB; peak memory now %.0f MB",
                             Date().timeIntervalSince(stopAt), d, size, Self.residentMB()))
                try? FileManager.default.removeItem(at: url)
                return
            }
        }
        print("FAIL no output after 30 min")
    }

    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }

    // MARK: Reporting

    private func check(_ ok: Bool, _ name: String, _ detail: String = "") {
        print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
        if !ok { failures += 1 }
    }

    private func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }

    // MARK: Region picker

    private var screen: NSScreen { NSScreen.main! }

    private func event(_ type: NSEvent.EventType, _ p: NSPoint, in view: NSView, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    /// Delivers an event the way AppKit does for a real click: through the
    /// window, which hit-tests and routes drags to the view that got mouse-down.
    private func send(_ view: NSView, _ e: NSEvent) {
        view.window?.sendEvent(e)
    }

    private func key(_ code: UInt16, in view: NSView) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: view.window!.windowNumber,
                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    /// Opens the picker, runs `interact` on the main screen's view, returns the result.
    private func pick(remembered: CGRect?, _ interact: (OverlayView) async -> Void) async -> CaptureTarget? {
        let picker = SelectionOverlay()
        var regions: [String: CGRect] = [:]
        if let remembered { regions[screen.displayID.stableUUID] = remembered }
        let task = Task { await picker.select(.region, remembered: regions, actionTitle: "Record") }
        await wait(0.4)
        guard let view = picker.viewsForTesting.first(where: { $0.screen == screen }) else {
            check(false, "region picker opened")
            return nil
        }
        await interact(view)
        await wait(0.2)
        if picker.viewsForTesting.isEmpty == false { view.keyDown(with: key(53, in: view)) } // Esc if still open
        return await task.value
    }

    /// View coords (bottom-left) for a display-local top-left rect corner.
    private func viewPoint(_ view: NSView, x: CGFloat, yTop: CGFloat) -> NSPoint {
        NSPoint(x: x, y: view.bounds.height - yTop)
    }

    private func regionPicker() async {
        let r = CGRect(x: 200, y: 150, width: 600, height: 400)

        // Enter accepts the remembered region.
        let a = await pick(remembered: r) { view in view.keyDown(with: key(36, in: view)) }
        check(a == .region(screen.displayID, r), "region: remembered region preselected, Enter confirms", "\(String(describing: a))")

        // Dragging the bottom-right handle resizes.
        let b = await pick(remembered: r) { view in
            let start = viewPoint(view, x: r.maxX, yTop: r.maxY)
            let end = viewPoint(view, x: r.maxX + 100, yTop: r.maxY + 50)
            send(view, event(.leftMouseDown, start, in: view))
            send(view, event(.leftMouseDragged, end, in: view))
            send(view, event(.leftMouseUp, end, in: view))
            view.keyDown(with: key(36, in: view))
        }
        check(b == .region(screen.displayID, CGRect(x: 200, y: 150, width: 700, height: 450)), "region: drag handle resizes", "\(String(describing: b))")

        // Dragging inside moves without resizing.
        let c = await pick(remembered: r) { view in
            let start = viewPoint(view, x: r.midX, yTop: r.midY)
            let end = viewPoint(view, x: r.midX + 40, yTop: r.midY + 30)
            send(view, event(.leftMouseDown, start, in: view))
            send(view, event(.leftMouseDragged, end, in: view))
            send(view, event(.leftMouseUp, end, in: view))
            view.keyDown(with: key(36, in: view))
        }
        check(c == .region(screen.displayID, CGRect(x: 240, y: 180, width: 600, height: 400)), "region: drag inside moves", "\(String(describing: c))")

        // Dragging outside draws a new region; edges within 8pt snap to the screen.
        let d = await pick(remembered: r) { view in
            let start = viewPoint(view, x: 5, yTop: 4)
            let end = viewPoint(view, x: 150, yTop: 100)
            send(view, event(.leftMouseDown, start, in: view))
            send(view, event(.leftMouseDragged, end, in: view))
            send(view, event(.leftMouseUp, end, in: view))
            view.keyDown(with: key(36, in: view))
        }
        check(d == .region(screen.displayID, CGRect(x: 0, y: 0, width: 150, height: 100)), "region: new drag + edge snapping", "\(String(describing: d))")

        // Draw a new region, then click-drag inside it to move it.
        let h = await pick(remembered: nil) { view in
            let a = viewPoint(view, x: 400, yTop: 300), b = viewPoint(view, x: 700, yTop: 500)
            send(view, event(.leftMouseDown, a, in: view))
            send(view, event(.leftMouseDragged, b, in: view))
            send(view, event(.leftMouseUp, b, in: view))
            let inside = viewPoint(view, x: 550, yTop: 400), moved = viewPoint(view, x: 600, yTop: 380)
            send(view, event(.leftMouseDown, inside, in: view))
            send(view, event(.leftMouseDragged, moved, in: view))
            send(view, event(.leftMouseUp, moved, in: view))
            view.keyDown(with: key(36, in: view))
        }
        check(h == .region(screen.displayID, CGRect(x: 450, y: 280, width: 300, height: 200)), "region: draw, then drag inside to move", "\(String(describing: h))")

        // A quick second click inside (macOS may call it a double-click) starts
        // a move; it must not capture.
        let e = await pick(remembered: r) { view in
            let p = viewPoint(view, x: r.midX, yTop: r.midY), q = viewPoint(view, x: r.midX + 10, yTop: r.midY + 10)
            send(view, event(.leftMouseDown, p, in: view, clicks: 2))
            send(view, event(.leftMouseDragged, q, in: view))
            send(view, event(.leftMouseUp, q, in: view))
            view.keyDown(with: key(36, in: view))
        }
        check(e == .region(screen.displayID, r.offsetBy(dx: 10, dy: 10)), "region: quick re-click inside moves (doesn't capture)", "\(String(describing: e))")

        // Esc cancels.
        let f = await pick(remembered: r) { view in view.keyDown(with: key(53, in: view)) }
        check(f == nil, "region: Esc cancels")

        // A tiny click (no drag) on empty space doesn't confirm anything.
        let g = await pick(remembered: nil) { view in
            let p = viewPoint(view, x: 300, yTop: 300)
            send(view, event(.leftMouseDown, p, in: view))
            send(view, event(.leftMouseUp, p, in: view))
            view.keyDown(with: key(36, in: view))
        }
        check(g == nil, "region: stray click makes no region")
    }

    /// ⌘⇧5-style: in Region mode the toolbar shows the last selection, which
    /// can be moved before capturing.
    private func toolbarRegion() async {
        let r = CGRect(x: 300, y: 200, width: 500, height: 300)
        app.state.session.lastRegions = [screen.displayID.stableUUID: r]
        app.state.session.mode = .region
        app.state.session.action = .screenshot
        app.showToolbar()
        await wait(0.5)
        guard let overlay = app.regionOverlay, let view = overlay.viewsForTesting.first(where: { $0.screen == screen }) else {
            check(false, "toolbar: region selection shown with toolbar")
            app.closeToolbar()
            return
        }
        check(overlay.currentTarget == .region(screen.displayID, r), "toolbar: last region shown with the toolbar")

        // Drag inside to move it.
        let start = viewPoint(view, x: r.midX, yTop: r.midY)
        let end = viewPoint(view, x: r.midX + 120, yTop: r.midY - 60)
        send(view, event(.leftMouseDown, start, in: view))
        send(view, event(.leftMouseDragged, NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2), in: view))
        send(view, event(.leftMouseDragged, end, in: view))
        send(view, event(.leftMouseUp, end, in: view))
        let moved = CGRect(x: 420, y: 140, width: 500, height: 300)
        check(overlay.currentTarget == .region(screen.displayID, moved), "toolbar: drag inside moves the selection",
              "\(String(describing: overlay.currentTarget))")

        // Enter captures what's selected (the toolbar's Capture does the same).
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? [])
        view.keyDown(with: key(36, in: view))
        var shot: URL?
        for _ in 0..<50 {
            await wait(0.2)
            let now = Set((try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? [])
            if let f = now.subtracting(before).first(where: { $0.hasSuffix(".png") }) { shot = outDir.appending(path: f); break }
        }
        let size = shot.flatMap { NSImageRep(contentsOf: $0) }.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
        let scale = screen.backingScaleFactor
        check(size == CGSize(width: 500 * scale, height: 300 * scale) && app.toolbar == nil && app.regionOverlay == nil,
              "toolbar: capture uses the moved selection and closes", "\(String(describing: size))")
        check(app.state.session.lastRegions[screen.displayID.stableUUID] == moved, "toolbar: moved selection is remembered")

        // No previous selection: nothing preselected; you draw one.
        app.state.session.lastRegions = [:]
        app.showToolbar()
        await wait(0.5)
        check(app.regionOverlay != nil && app.regionOverlay?.currentTarget == nil, "toolbar: no previous selection → draw your own")
        app.closeToolbar()
        app.state.session.lastRegions = [screen.displayID.stableUUID: moved]

        // Esc on the overlay closes everything.
        app.showToolbar()
        await wait(0.5)
        if let v = app.regionOverlay?.viewsForTesting.first { v.keyDown(with: key(53, in: v)) }
        await wait(0.3)
        check(app.toolbar == nil && app.regionOverlay == nil, "toolbar: Esc closes toolbar and selection")
    }

    private func windowPicker() async {
        // The window picker should ignore reel's own windows and pick the topmost app window.
        let picker = SelectionOverlay()
        let task = Task { await picker.select(.window) }
        await wait(0.4)
        let views = picker.viewsForTesting
        if let view = views.first { view.keyDown(with: key(53, in: view)) }
        let result = await task.value
        check(!views.isEmpty && result == nil, "window picker opens and Esc cancels")
    }

    // MARK: Recordings

    /// A normal app window to capture (not reel's).
    private func someWindow() -> (CGWindowID, CGRect)? {
        let pid = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != pid,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let b = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  b.width > 200, b.height > 200 else { continue }
            return (id, b)
        }
        return nil
    }

    private func windowCapture() async {
        guard let (id, bounds) = someWindow() else {
            check(false, "window capture", "no app window on screen to capture")
            return
        }
        do {
            let shot = try await Screenshotter.capture(.window(id))
            let expect = (bounds.width * shot.scale, bounds.height * shot.scale)
            check(abs(CGFloat(shot.image.width) - expect.0) <= 2 && abs(CGFloat(shot.image.height) - expect.1) <= 2,
                  "window screenshot matches window size", "\(shot.image.width)×\(shot.image.height)")
        } catch {
            check(false, "window screenshot", "\(error)")
        }
        let url = await record(.window(id), seconds: 1.5)
        if let url {
            let size = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first?.load(.naturalSize)
            check(size.map { $0.width > 100 && $0.height > 100 } ?? false, "window recording", "\(size.map { "\(Int($0.width))×\(Int($0.height))" } ?? "no video")")
        }
    }

    private var testRegion: CaptureTarget { .region(screen.displayID, CGRect(x: 100, y: 100, width: 640, height: 400)) }

    /// Runs a full RecordingSession and returns the saved file.
    private func record(_ target: CaptureTarget, seconds: Double, during: ((RecordingSession) async -> Void)? = nil) async -> URL? {
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? [])
        let session = RecordingSession(state: app.state, target: target, thumbnails: app.thumbnails, webcam: app.webcam)
        await session.start()
        if let during { await during(session) } else { await wait(seconds) }
        session.stop()
        for _ in 0..<100 {
            await wait(0.2)
            let now = Set((try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? [])
            if let new = now.subtracting(before).first(where: { $0.hasSuffix(".mp4") }) {
                return outDir.appending(path: new)
            }
        }
        check(false, "recording saved", "no file after 20s")
        return nil
    }

    private func duration(_ url: URL) async -> Double {
        (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
    }

    private func countdown() async {
        var config = app.state.config
        config.countdown = 3
        app.state.overrideConfig(config)
        let started = Date()
        let url = await record(testRegion, seconds: 2)
        config.countdown = 0
        app.state.overrideConfig(config)
        guard let url else { return }
        let d = await duration(url)
        // The countdown isn't part of the video: ~2s recorded after a 3s countdown.
        check(d > 1.6 && d < 2.6 && Date().timeIntervalSince(started) > 4.8, "countdown runs, then records", String(format: "video %.2fs", d))
    }

    private func border() async {
        var config = app.state.config
        config.recordingBorder = true
        app.state.overrideConfig(config)
        var sawBorder = false
        let url = await record(testRegion, seconds: 0) { _ in
            await self.wait(1)
            let pid = ProcessInfo.processInfo.processIdentifier
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            let r = CGRect(x: 100, y: 100, width: 640, height: 400).offsetBy(dx: CGDisplayBounds(self.screen.displayID).minX,
                                                                            dy: CGDisplayBounds(self.screen.displayID).minY)
            sawBorder = list.contains { info in
                guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                      let b = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) })
                else { return false }
                return b.contains(r) && b.width < r.width + 40   // just around the region
            }
            await self.wait(0.5)
        }
        config.recordingBorder = false
        app.state.overrideConfig(config)
        check(sawBorder, "recording border shown around region")
        if let url {
            let size = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first?.load(.naturalSize)
            // The video is exactly the region (border sits outside it).
            check(size == CGSize(width: 640 * screen.backingScaleFactor, height: 400 * screen.backingScaleFactor),
                  "border not in video (video = region size)", "\(String(describing: size))")
        }
    }

    private func pauseResume() async {
        let url = await record(testRegion, seconds: 0) { session in
            await self.wait(1.5)
            session.togglePause()
            await self.wait(1.5)
            session.togglePause()
            await self.wait(1.5)
        }
        guard let url else { return }
        let d = await duration(url)
        let tracks = (try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first?.load(.timeRange)).map { "\($0.start.seconds)+\($0.duration.seconds)" } ?? "?"
        print("  pause detail: track \(tracks)")
        check(d > 2.6 && d < 3.5, "pause/resume: paused time is cut", String(format: "video %.2fs of 4.5s wall time", d))
    }

    private func cancel() async {
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? [])
        let session = RecordingSession(state: app.state, target: testRegion, thumbnails: app.thumbnails, webcam: app.webcam)
        await session.start()
        await wait(1)
        session.cancel()
        await wait(1.5)
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? [])
        check(after == before && !app.state.isRecording, "cancel discards the recording")
    }

    private func systemStop() async {
        let url = await record(testRegion, seconds: 0) { session in
            await self.wait(2)
            await session.simulateSystemStop()
            await self.wait(0.5)
        }
        guard let url else { return }
        let d = await duration(url)
        check(d > 1.5 && d < 2.8 && !app.state.isRecording, "stopped by macOS: partial recording is saved", String(format: "video %.2fs", d))
    }

    private func systemStopUnattended() async {
        // Same, but nobody presses stop: reel recovers on its own.
        let url = await record(testRegion, seconds: 0) { session in
            await self.wait(2)
            await session.simulateSystemStop()
            await self.wait(3)
        }
        guard let url else { return }
        let d = await duration(url)
        check(d > 1.5 && d < 2.8, "stopped by macOS, no user action: still saved", String(format: "video %.2fs", d))
    }

    /// The real flow: thumbnail → Trim… → take longer than the auto-save
    /// countdown → Trim. The file must actually get shorter.
    private func trimFromThumbnail() async {
        guard let source = await record(testRegion, seconds: 4) else { return }
        let scratch = SaveLocation.workDirectory()
        let temp = scratch.appending(path: "trim-test.mp4")
        try? FileManager.default.copyItem(at: source, to: temp)
        let dest = outDir.appending(path: "trimmed", directoryHint: .isDirectory)
        await app.thumbnails.present(tempURL: temp, destination: dest, seconds: 2)
        guard let panel = NSApp.windows.compactMap({ $0 as? ThumbnailPanel }).last,
              let view = panel.contentView as? ThumbnailView else {
            check(false, "trim from thumbnail", "no thumbnail")
            return
        }
        view.trimForTesting()
        await wait(7) // longer than the thumbnail's 2s countdown
        check(panel.isVisible, "trim: thumbnail stays up while trimming")
        guard let complete = TrimWindow.completeForTesting else {
            check(false, "trim: trim window opened")
            return
        }
        complete(CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600), end: CMTime(seconds: 3, preferredTimescale: 600)))
        await wait(3)
        let saved = ((try? FileManager.default.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)) ?? []).first
        var d = 0.0
        if let saved { d = await duration(saved) }
        check(abs(d - 2) < 0.15, "trim: file is actually trimmed", String(format: "%.2fs (was ~4s)", d))
        try? FileManager.default.removeItem(at: scratch)
    }

    private func trimWindowCancel() async {
        guard let file = ((try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? []).first(where: { $0.hasSuffix(".mp4") }) else {
            check(false, "trim window", "no file to open")
            return
        }
        var result: CMTimeRange?? = .none
        TrimWindow.show(outDir.appending(path: file)) { range in result = .some(range) }
        await wait(1.5)
        let window = NSApp.windows.first { $0.title.hasPrefix("Trim ") && $0.isVisible }
        check(window != nil, "trim window opens")
        window?.close()
        await wait(0.3)
        check(result != nil && result! == nil, "trim window: closing cancels without changes")
    }
}
#endif
