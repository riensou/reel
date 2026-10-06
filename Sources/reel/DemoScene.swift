#if DEBUG
import AppKit
import ReelCore
import SwiftUI

/// Stages and records the README demo (`reel --demo-scene out.mp4`).
///
/// A clean backdrop with a sample window covers the desktop, then reel's real
/// UI runs through a typical recording: toolbar → Region + Record → region
/// picker → recording with keystrokes → thumbnail. reel records all of it
/// (including its own windows), and the cursor is drawn afterwards from a
/// scripted path using the same smoothing as the smooth-cursor feature.
@MainActor
final class DemoScene {
    private let app: AppDelegate
    private var state: AppState { app.state }
    private let recorder = Recorder()
    private var log: EventLog!
    private var cursor = NSPoint.zero
    private var captureRect = NSRect.zero  // NS global points
    private let typed = DemoText()

    init(app: AppDelegate) {
        self.app = app
    }

    func run(output: URL) async throws {
        guard let screen = NSScreen.main else { return }
        let savedSession = state.session
        defer { state.session = savedSession }

        // Backdrop: above normal apps, below reel's toolbar.
        let backdrop = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        backdrop.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        backdrop.isOpaque = true
        backdrop.hasShadow = false
        backdrop.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let window = Self.sampleWindowRect(in: screen)
        backdrop.contentView = NSHostingView(rootView: DemoBackdrop(window: window.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY),
                                                                    screenSize: screen.frame.size, typed: typed))
        backdrop.setFrame(screen.frame, display: true)
        backdrop.orderFrontRegardless()
        defer { backdrop.orderOut(nil) }

        // Start in screenshot mode with the sample window as the remembered region.
        let displayID = screen.displayID
        state.session.mode = .screen
        state.session.action = .screenshot
        state.session.systemAudio = false
        state.session.microphone = false
        state.session.showCursor = true
        let region = CGRect(x: window.minX - screen.frame.minX, y: screen.frame.maxY - window.maxY,
                            width: window.width, height: window.height).integral
        state.session.lastRegions[displayID.stableUUID] = region

        // Record the visible area (no menu bar or Dock), reel's windows included.
        let vf = screen.visibleFrame
        captureRect = vf
        var options = CaptureOptions()
        options.includeOwnWindows = true
        options.cursor.show = false
        options.fps = 60
        let local = CGRect(x: vf.minX - screen.frame.minX, y: screen.frame.maxY - vf.maxY, width: vf.width, height: vf.height)
        try await Task.sleep(for: .milliseconds(400))
        try await recorder.start(.region(displayID, local), options: options)
        log = EventLog(frameSize: recorder.frameSize, scale: recorder.pointScale)
        log.cursors[0] = Self.arrowImage()
        cursor = NSPoint(x: window.midX + 140, y: window.midY - 60)
        await hold(0.8)

        // 1. Open the toolbar.
        app.showToolbar()
        await hold(0.7)
        guard let bar = app.toolbar?.frame else { return }

        // 2. Region mode, then Record.
        await move(to: NSPoint(x: bar.minX + 130, y: bar.midY), over: 0.8)
        click { self.state.session.mode = .region }
        await hold(0.5)
        await move(to: NSPoint(x: bar.minX + 208, y: bar.midY), over: 0.45)
        click { withAnimation(Design.animation) { self.state.session.action = .record } }
        await hold(0.7)
        guard let wide = app.toolbar?.frame else { return }
        await move(to: NSPoint(x: wide.maxX - 44, y: wide.midY), over: 0.6)
        click {}
        await hold(0.15)

        // 3. Region picker, opening on the remembered region.
        app.closeToolbar()
        let picker = SelectionOverlay()
        let picked = Task { await picker.select(.region, remembered: state.session.lastRegions, actionTitle: "Record") }
        await hold(1.0)
        await move(to: NSPoint(x: window.midX + 36, y: window.minY - 26), over: 0.8)
        click { picker.confirmForDemo() }
        guard let target = await picked.value else { return }

        // 4. "Recording": border + keystrokes.
        let border = RecordingBorder(target: target)
        border.show()
        let keys = KeystrokeHUD(mode: .all)
        keys.startDisplayOnly(over: window)
        await hold(0.6)
        // Click into the empty line under the checklist, then type.
        await move(to: NSPoint(x: window.minX + 60, y: window.maxY - 215), over: 0.7)
        click { self.typed.focused = true }
        await hold(0.3)
        // Move the mouse out of the way, toward the middle, like you would before typing.
        await move(to: NSPoint(x: window.midX + 60, y: window.midY - 70), over: 0.7)
        await hold(0.2)
        for ch in "hello world" {
            keys.simulate(ch == " " ? .named("Space") : .char(String(ch)))
            typed.text.append(ch)
            await hold(0.12)
        }
        await hold(0.5)
        keys.simulate(.shortcut("⌘S"))
        await hold(1.2)

        // 5. Stop → thumbnail.
        keys.stop()
        border.hide()
        let preview = try await Screenshotter.capture(.region(displayID, region), options: options)
        let scratch = SaveLocation.workDirectory()
        let fake = scratch.appending(path: "demo.mp4")
        FileManager.default.createFile(atPath: fake.path, contents: Data())
        let thumb = app.thumbnails.present(image: NSImage(cgImage: preview.image, size: .zero), isVideo: true,
                                           destination: scratch.appending(path: "out"), seconds: 30)
        for i in 1...12 {
            thumb.setProgress(Double(i) / 12)
            await hold(0.06)
        }
        thumb.ready(fake)
        await move(to: NSPoint(x: thumb.frame.midX, y: thumb.frame.midY), over: 1.0)
        await hold(0.3)
        click {}
        await hold(2.4)

        // Finish: draw the cursor and write the video.
        log.duration = recorder.activeTime
        let recording = try await recorder.stop()
        thumb.discard()
        var job = Finisher.Job(segments: recording.segments, output: output)
        job.effect = DemoEffects.make(log: log, autoZoom: true, zoomScale: 1.7, smoothCursor: true)
        try await Finisher.run(job)
        try? FileManager.default.removeItem(at: recording.workDirectory)
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Scripted cursor

    private func framePoint(_ p: NSPoint) -> CGPoint {
        CGPoint(x: (p.x - captureRect.minX) * log.scale, y: (captureRect.maxY - p.y) * log.scale)
    }

    private func sample() {
        log.samples.append(.init(t: recorder.activeTime, p: framePoint(cursor), cursor: 0))
    }

    /// Waits in real time while logging the (still) cursor.
    private func hold(_ seconds: Double) async {
        let end = Date.now.addingTimeInterval(seconds)
        while Date.now < end {
            sample()
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    /// Eased glide to `target`, in real time.
    private func move(to target: NSPoint, over seconds: Double) async {
        let start = cursor
        let begin = Date.now
        while true {
            let u = min(1, Date.now.timeIntervalSince(begin) / seconds)
            let e = u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
            cursor = NSPoint(x: start.x + (target.x - start.x) * e, y: start.y + (target.y - start.y) * e)
            sample()
            if u >= 1 { break }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private func click(_ action: () -> Void) {
        log.clicks.append(.init(t: recorder.activeTime, p: framePoint(cursor)))
        action()
    }

    private static func arrowImage() -> EventLog.CursorImage {
        let arrow = NSCursor.arrow
        let tiff = arrow.image.tiffRepresentation!
        let rep = NSBitmapImageRep.imageReps(with: tiff).compactMap { $0 as? NSBitmapImageRep }
            .max { $0.pixelsWide < $1.pixelsWide }!
        return .init(png: rep.representation(using: .png, properties: [:])!, size: arrow.image.size, hotspot: arrow.hotSpot)
    }

    static func sampleWindowRect(in screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let size = NSSize(width: min(860, vf.width * 0.6), height: min(520, vf.height * 0.55))
        return NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2 + 40, width: size.width, height: size.height).integral
    }
}

@MainActor
private final class DemoText: ObservableObject {
    @Published var text = ""
    @Published var focused = false
}

/// Calm wallpaper with a simple notes-style window.
private struct DemoBackdrop: View {
    let window: NSRect      // in backdrop coordinates (bottom-left origin)
    let screenSize: CGSize
    @ObservedObject var typed: DemoText

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.62), Color(red: 0.55, green: 0.47, blue: 0.62)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            SampleWindow(typed: typed)
                .frame(width: window.width, height: window.height)
                .offset(x: window.minX, y: screenSize.height - window.maxY)
        }
        .ignoresSafeArea()
    }
}

private struct SampleWindow: View {
    @ObservedObject var typed: DemoText

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 12, height: 12)
                Spacer()
                Text("Notes").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Color.clear.frame(width: 52, height: 1)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Launch checklist").font(.system(size: 24, weight: .bold))
                ForEach(["Record the demo", "Write the README", "Post it"], id: \.self) { item in
                    HStack(spacing: 10) {
                        Image(systemName: "circle").foregroundStyle(.tertiary)
                        Text(item).font(.system(size: 16))
                    }
                }
                HStack(spacing: 1) {
                    Text(typed.text).font(.system(size: 16))
                    if typed.focused {
                        Rectangle().fill(Color.accentColor).frame(width: 2, height: 19)
                    }
                }
                .padding(.top, 10)
                .frame(height: 24)
                Spacer()
            }
            .padding(24)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
    }
}
#endif
