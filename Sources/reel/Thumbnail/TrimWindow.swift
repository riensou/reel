import AVKit
import AppKit

/// QuickTime-style trimming: a small player window that opens straight into
/// the trim bar. Calls back with the kept range, or nil if cancelled.
@MainActor
enum TrimWindow {
    private static var open: [NSWindow] = []

    static func show(_ url: URL, completion: @escaping (CMTimeRange?) -> Void) {
        let player = AVPlayer(url: url)
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = false

        let asset = AVURLAsset(url: url)
        Task {
            let size = (try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)) ?? CGSize(width: 1280, height: 800)
            let fit = min(900 / size.width, 560 / size.height, 1)
            let content = NSSize(width: max(480, size.width * fit), height: max(300, size.height * fit))

            let window = NSWindow(contentRect: NSRect(origin: .zero, size: content),
                                  styleMask: [.titled, .closable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Trim \(url.lastPathComponent)"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.center()
            open.append(window)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)

            var finished = false
            @MainActor func done(_ range: CMTimeRange?) {
                guard !finished else { return }
                finished = true
                player.pause()
                window.close()
                open.removeAll { $0 === window }
                completion(range)
            }
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { done(nil) }
            }
            // Wait for the item so the trim UI is available.
            while player.currentItem?.status != .readyToPlay {
                try? await Task.sleep(for: .milliseconds(50))
            }
            let result = await view.beginTrimming()
            guard result == .okButton, let item = player.currentItem else { return done(nil) }
            // Invalid times mean that handle wasn't moved.
            let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
            let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
            done(CMTimeRange(start: start, end: end))
        }
    }
}
