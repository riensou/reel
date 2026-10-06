import AppKit
import Carbon.HIToolbox
import Combine
import ReelCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let state = AppState()
    private let recorder = Recorder()
    private let thumbnails = ThumbnailController()
    private var toolbar: ToolbarPanel?
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var tick: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusItem()

        // ⌘⇧6: open the toolbar, or stop the current recording.
        hotKey = HotKey(keyCode: kVK_ANSI_6, modifiers: cmdKey | shiftKey) { [weak self] in
            MainActor.assumeIsolated { self?.hotKeyPressed() }
        }

        recorder.onUnexpectedStop = { [weak self] error in
            DispatchQueue.main.async {
                self?.recordingEnded()
                self?.showError(error)
            }
        }

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    // MARK: Entry points

    private func hotKeyPressed() {
        if state.isRecording {
            stopRecording()
        } else if toolbar != nil {
            closeToolbar()
        } else {
            showToolbar()
        }
    }

    @objc private func statusItemClicked() {
        if state.isRecording {
            stopRecording()
            return
        }
        statusItem.menu = buildMenu()
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Detach so the next left-click goes back through statusItemClicked.
        statusItem.menu = nil
    }

    @objc private func showToolbar() {
        closeToolbar()
        let panel = ToolbarPanel(
            state: state,
            onCapture: { [weak self] in self?.captureFromToolbar() },
            onCancel: { [weak self] in self?.closeToolbar() }
        )
        toolbar = panel
        panel.present(on: NSScreen.underMouse ?? NSScreen.screens[0])
    }

    private func closeToolbar() {
        toolbar?.orderOut(nil)
        toolbar = nil
    }

    private func captureFromToolbar() {
        closeToolbar()
        run(mode: state.prefs.mode, action: state.prefs.action)
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let (mode, action) = sender.representedObject as? (CaptureMode, CaptureAction) else { return }
        run(mode: mode, action: action)
    }

    // MARK: Capture

    private func run(mode: CaptureMode, action: CaptureAction) {
        Task {
            let target: CaptureTarget?
            switch mode {
            case .screen: target = .display((NSScreen.underMouse ?? NSScreen.screens[0]).displayID)
            case .region: target = await SelectionOverlay().select(.region)
            case .window: target = await SelectionOverlay().select(.window)
            }
            guard let target else { return }
            switch action {
            case .screenshot: await screenshot(target)
            case .record: await startRecording(target)
            }
        }
    }

    private func screenshot(_ target: CaptureTarget) async {
        do {
            let shot = try await Screenshotter.capture(target, options: state.prefs.options)
            let temp = SaveLocation.temporaryURL(for: .screenshot)
            try Screenshotter.writePNG(shot, to: temp)
            NSSound(named: "Grab")?.play()
            await deliver(temp, kind: .screenshot)
        } catch {
            showError(error)
        }
    }

    private func startRecording(_ target: CaptureTarget) async {
        let options = state.prefs.options
        let temp = SaveLocation.temporaryURL(for: .recording)
        do {
            try await recorder.start(target, options: options, to: temp)
        } catch {
            showError(error)
            return
        }
        state.isRecording = true
        state.recordingStartedAt = .now
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusItem() }
        }
        updateStatusItem()
    }

    @objc private func stopRecording() {
        Task {
            do {
                let url = try await recorder.stop()
                recordingEnded()
                await deliver(url, kind: .recording)
            } catch {
                recordingEnded()
                showError(error)
            }
        }
    }

    private func recordingEnded() {
        tick?.invalidate()
        tick = nil
        state.isRecording = false
        state.recordingStartedAt = nil
        updateStatusItem()
    }

    private func deliver(_ temp: URL, kind: SaveLocation.Kind) async {
        let dir = state.saveDirectory(for: kind)
        if state.prefs.showThumbnail {
            await thumbnails.present(tempURL: temp, destination: dir, seconds: state.prefs.thumbnailSeconds)
        } else {
            do { try SaveLocation.commit(temp, to: dir) } catch { showError(error) }
        }
    }

    // MARK: Menu bar

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        if state.isRecording, let start = state.recordingStartedAt {
            let s = Int(Date.now.timeIntervalSince(start))
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")
            button.contentTintColor = .systemRed
            button.title = String(format: " %d:%02d", s / 60, s % 60)
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        } else {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "reel")
            button.contentTintColor = nil
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let toolbarItem = menu.addItem(withTitle: "Capture Toolbar", action: #selector(showToolbar), keyEquivalent: "6")
        toolbarItem.keyEquivalentModifierMask = [.command, .shift]
        toolbarItem.target = self
        menu.addItem(.separator())

        for (title, mode, action) in [
            ("Screenshot Region", CaptureMode.region, CaptureAction.screenshot),
            ("Screenshot Window", .window, .screenshot),
            ("Screenshot Screen", .screen, .screenshot),
            ("Record Region", .region, .record),
            ("Record Window", .window, .record),
            ("Record Screen", .screen, .record),
        ] {
            let item = menu.addItem(withTitle: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = (mode, action)
        }

        menu.addItem(.separator())
        addToggle(to: menu, "Record System Audio", \.options.systemAudio)
        addToggle(to: menu, "Record Microphone", \.options.microphone)
        addToggle(to: menu, "Show Cursor", \.options.cursor.show)
        addToggle(to: menu, "Floating Thumbnail", \.showThumbnail)

        menu.addItem(.separator())
        let folder = state.saveDirectory(for: .screenshot)
        let open = menu.addItem(withTitle: "Open \(folder.lastPathComponent)", action: #selector(openSaveFolder), keyEquivalent: "")
        open.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit reel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private func addToggle(to menu: NSMenu, _ title: String, _ path: WritableKeyPath<Preferences, Bool>) {
        let item = ToggleItem(title: title, path: path, state: state)
        menu.addItem(item)
    }

    @objc private func openSaveFolder() {
        NSWorkspace.shared.open(state.saveDirectory(for: .screenshot))
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "reel couldn't capture"
        alert.informativeText = error.localizedDescription
        if !CGPreflightScreenCaptureAccess() {
            alert.informativeText += "\n\nreel needs Screen Recording permission in System Settings → Privacy & Security."
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        NSApp.activate()
        alert.runModal()
    }
}

/// Menu item bound to a Bool preference.
private final class ToggleItem: NSMenuItem {
    private let path: WritableKeyPath<Preferences, Bool>
    private let appState: AppState

    @MainActor
    init(title: String, path: WritableKeyPath<Preferences, Bool>, state: AppState) {
        self.path = path
        self.appState = state
        super.init(title: title, action: #selector(toggle), keyEquivalent: "")
        target = self
        self.state = state.prefs[keyPath: path] ? .on : .off
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func toggle() {
        MainActor.assumeIsolated { appState.prefs[keyPath: path].toggle() }
    }
}
