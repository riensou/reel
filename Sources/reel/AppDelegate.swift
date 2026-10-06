import AppKit
import Combine
import ReelCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let state = AppState()
    let thumbnails = ThumbnailController()
    private lazy var webcam = WebcamBubble(state: state)
    private lazy var settings = SettingsWindowController(state: state, actions: .init(
        openConfig: { [weak self] in self?.openConfigFile() },
        revealConfig: { [weak self] in self?.revealConfigFile() }
    ))
    private(set) var toolbar: ToolbarPanel?
    private var recording: RecordingSession?
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var registeredHotKey: KeyCombo?
    private var tick: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    private var lastConfig: Config?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusItem()

        lastConfig = state.config
        registerHotKey()
        state.configFile.watch { [weak self] in
            MainActor.assumeIsolated { self?.state.reloadConfig() }
        }
        state.$config.removeDuplicates().dropFirst().sink { [weak self] new in
            self?.configChanged(new)
        }.store(in: &subscriptions)
        state.$configWarnings.removeDuplicates().sink { [weak self] warnings in
            guard let first = warnings.first else { return }
            let more = warnings.count > 1 ? " (+\(warnings.count - 1) more)" : ""
            Toast.error("Config \(first)\(more)", action: Toast.Action(title: "Edit") { self?.openConfigFile() })
        }.store(in: &subscriptions)
        Publishers.CombineLatest(state.$isRecording, state.$isPaused).sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }.store(in: &subscriptions)

        syncLaunchAtLogin()
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }

        // Dev conveniences: open a surface on launch (`--show-settings demo`, `--show-toolbar`).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--show-settings") {
            let tab = args.indices.contains(i + 1) ? SettingsTab(rawValue: args[i + 1]) : nil
            settings.show(tab: tab ?? .general)
        }
        if args.contains("--show-toolbar") { showToolbar() }
        if args.contains("--show-webcam") { webcam.show() }
        if let i = args.firstIndex(of: "--demo-scene"), let out = args[safe: i + 1] {
            // Stages and records the README demo, then quits.
            Task {
                do {
                    try await DemoScene(app: self).run(output: URL(fileURLWithPath: out))
                    print(out)
                } catch {
                    FileHandle.standardError.write(Data("demo scene failed: \(error)\n".utf8))
                }
                NSApp.terminate(nil)
            }
        }
        if let i = args.firstIndex(of: "--dev-record"), let secs = Double(args[safe: i + 1] ?? "") {
            // Records the main display through the full pipeline, then stops.
            Task {
                await startRecording(.display(CGMainDisplayID()))
                try? await Task.sleep(for: .seconds(secs))
                recording?.stop()
            }
        }
    }

    // MARK: Config

    private func configChanged(_ config: Config) {
        if config.hotkey != registeredHotKey { registerHotKey() }
        if config.launchAtLogin != lastConfig?.launchAtLogin { syncLaunchAtLogin() }
        if let last = lastConfig, last.webcamSize != config.webcamSize || last.webcamShape != config.webcamShape {
            webcam.refresh()
        }
        if !config.webcam, recording == nil { webcam.hide() }
        lastConfig = config
    }

    /// Opens the toolbar, or stops the current recording.
    private func registerHotKey() {
        let combo = state.config.hotkey
        hotKey = nil
        hotKey = HotKey(keyCode: combo.keyCode, modifiers: combo.carbonModifiers) { [weak self] in
            MainActor.assumeIsolated { self?.hotKeyPressed() }
        }
        registeredHotKey = combo
    }

    private func syncLaunchAtLogin() {
        let service = SMAppService.mainApp
        let want = state.config.launchAtLogin
        guard want != (service.status == .enabled) else { return }
        do {
            if want { try service.register() } else { try service.unregister() }
        } catch {
            Toast.error("Couldn't \(want ? "enable" : "disable") launch at login: \(error.localizedDescription)")
        }
    }

    func openConfigFile() {
        let url = state.configFile.url
        // Prefer the user's text editor over whatever claims extensionless files.
        if let editor = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: "/tmp/reel.txt")) {
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func revealConfigFile() {
        NSWorkspace.shared.activateFileViewerSelecting([state.configFile.url])
    }

    // MARK: Entry points

    private func hotKeyPressed() {
        if let recording {
            recording.stop()
        } else if toolbar != nil {
            closeToolbar()
        } else {
            showToolbar()
        }
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true
        if let recording {
            if wantsMenu { popUp(recordingMenu()) } else { recording.stop() }
            return
        }
        popUp(buildMenu())
    }

    private func popUp(_ menu: NSMenu) {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Detach so the next click goes back through statusItemClicked.
        statusItem.menu = nil
    }

    @objc func showToolbar() {
        closeToolbar()
        let panel = ToolbarPanel(state: state, actions: .init(
            capture: { [weak self] in self?.captureFromToolbar() },
            cancel: { [weak self] in self?.closeToolbar() },
            openSettings: { [weak self] in self?.openSettings() },
            webcamChanged: { [weak self] visible in
                guard let self, self.recording == nil else { return }
                visible ? self.webcam.show() : self.webcam.hide()
            }
        ))
        toolbar = panel
        panel.present(on: NSScreen.underMouse ?? NSScreen.screens[0])
    }

    /// - Parameter keepWebcam: true when a recording is about to use the bubble.
    func closeToolbar(keepWebcam: Bool = false) {
        toolbar?.orderOut(nil)
        toolbar = nil
        if !keepWebcam, recording == nil { webcam.hide() }
    }

    private func captureFromToolbar() {
        let recordingWithWebcam = state.session.action == .record && state.config.webcam && state.session.webcamOn
        closeToolbar(keepWebcam: recordingWithWebcam)
        run(mode: state.session.mode, action: state.session.action)
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let (mode, action) = sender.representedObject as? (CaptureMode, CaptureAction) else { return }
        run(mode: mode, action: action)
    }

    @objc func openSettings() {
        closeToolbar()
        settings.show()
    }

    // MARK: Capture

    private func run(mode: CaptureMode, action: CaptureAction) {
        Task {
            let target: CaptureTarget?
            switch mode {
            case .screen:
                target = .display((NSScreen.underMouse ?? NSScreen.screens[0]).displayID)
            case .region:
                target = await SelectionOverlay().select(
                    .region, remembered: state.session.lastRegions,
                    actionTitle: action == .record ? "Record" : "Capture"
                )
                if case .region(let id, let rect)? = target {
                    state.session.lastRegions[id.stableUUID] = rect
                }
            case .window:
                target = await SelectionOverlay().select(.window)
            }
            guard let target else {
                webcam.hide()
                return
            }
            switch action {
            case .screenshot: await screenshot(target)
            case .record: await startRecording(target)
            }
        }
    }

    private func screenshot(_ target: CaptureTarget) async {
        do {
            let shot = try await Screenshotter.capture(target, options: state.captureOptions)
            let temp = SaveLocation.temporaryURL(for: .screenshot)
            try Screenshotter.writePNG(shot, to: temp)
            NSSound(named: "Grab")?.play()
            let dir = state.saveDirectory(for: .screenshot)
            if state.config.thumbnail {
                await thumbnails.present(tempURL: temp, destination: dir, seconds: state.config.thumbnailDuration)
            } else {
                let saved = try SaveLocation.commit(temp, to: dir)
                Toast.info("Saved \(saved.lastPathComponent)", action: .reveal(saved))
            }
        } catch {
            Toast.error(error)
        }
    }

    private func startRecording(_ target: CaptureTarget) async {
        guard recording == nil else { return }
        let session = RecordingSession(state: state, target: target, thumbnails: thumbnails, webcam: webcam)
        session.onEnd = { [weak self] in
            self?.recording = nil
            self?.tick?.invalidate()
            self?.tick = nil
        }
        recording = session
        tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusItem() }
        }
        await session.start()
    }

    // MARK: Menu bar

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        if state.isRecording, let recording {
            let s = Int(recording.elapsed)
            let paused = state.isPaused
            button.image = NSImage(systemSymbolName: paused ? "pause.circle.fill" : "stop.circle.fill",
                                   accessibilityDescription: paused ? "Paused" : "Stop recording")
            button.contentTintColor = paused ? .secondaryLabelColor : .systemRed
            button.title = String(format: " %d:%02d", s / 60, s % 60)
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.toolTip = "Click to stop · Right-click for more"
        } else {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "reel")
            button.contentTintColor = nil
            button.title = ""
            button.imagePosition = .imageOnly
            button.toolTip = "reel"
        }
    }

    private func recordingMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let pause = menu.addItem(withTitle: state.isPaused ? "Resume" : "Pause", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.image = NSImage(systemSymbolName: state.isPaused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
        let stop = menu.addItem(withTitle: "Stop", action: #selector(stopRecording), keyEquivalent: "")
        stop.target = self
        stop.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        menu.addItem(.separator())
        let cancel = menu.addItem(withTitle: "Cancel Recording", action: #selector(cancelRecording), keyEquivalent: "")
        cancel.target = self
        cancel.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        return menu
    }

    @objc private func togglePause() { recording?.togglePause() }
    @objc private func stopRecording() { recording?.stop() }
    @objc private func cancelRecording() { recording?.cancel() }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let toolbarItem = menu.addItem(withTitle: "Capture Toolbar", action: #selector(showToolbar), keyEquivalent: "")
        toolbarItem.target = self
        toolbarItem.toolTip = state.config.hotkey.symbols
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
        menu.addItem(ToggleItem(title: "Record System Audio", path: \.systemAudio, state: state))
        menu.addItem(ToggleItem(title: "Record Microphone", path: \.microphone, state: state))
        menu.addItem(ToggleItem(title: "Show Cursor", path: \.showCursor, state: state))

        menu.addItem(.separator())
        let folder = state.saveDirectory(for: .screenshot)
        menu.addItem(withTitle: "Open \(folder.lastPathComponent)", action: #selector(openSaveFolder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit reel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func openSaveFolder() {
        NSWorkspace.shared.open(state.saveDirectory(for: .screenshot))
    }
}

/// Menu item bound to a Bool in the session state.
private final class ToggleItem: NSMenuItem {
    private let path: WritableKeyPath<SessionState, Bool>
    private let appState: AppState

    @MainActor
    init(title: String, path: WritableKeyPath<SessionState, Bool>, state: AppState) {
        self.path = path
        self.appState = state
        super.init(title: title, action: #selector(toggle), keyEquivalent: "")
        target = self
        self.state = state.session[keyPath: path] ? .on : .off
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func toggle() {
        MainActor.assumeIsolated { appState.session[keyPath: path].toggle() }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
