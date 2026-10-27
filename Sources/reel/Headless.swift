import AppKit

/// Lets `reel --self-test` run the real UI code without taking over the
/// machine. In headless mode every reel window is ordered in *behind the
/// desktop* — still a real window for hit-testing, window lists and
/// ScreenCaptureKit, but invisible and unreachable by the mouse — and reel
/// never activates or takes key status, so keyboard focus stays where it was.
/// The self-test synthesizes its own mouse and key events, so none of that is
/// needed for the checks. Off in normal use; `--self-test … --watch` shows it.
@MainActor
enum Headless {
    static var enabled = false

    /// Behind Finder's desktop window on every display.
    private static let hiddenLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)

    /// Call once a window is configured (end of init or just before showing).
    static func prepare(_ window: NSWindow) {
        guard enabled else { return }
        window.level = hiddenLevel
        window.ignoresMouseEvents = true
        window.hasShadow = false
    }

    /// `NSApp.activate()`, except in headless mode.
    static func activate() {
        if !enabled { NSApp.activate() }
    }

    /// `makeKeyAndOrderFront`, or just order front in headless mode so an
    /// invisible panel can't swallow the user's typing.
    static func makeKeyAndOrderFront(_ window: NSWindow) {
        enabled ? window.orderFrontRegardless() : window.makeKeyAndOrderFront(nil)
    }
}
