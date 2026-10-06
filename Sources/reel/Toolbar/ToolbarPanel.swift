import AppKit
import ReelCore
import SwiftUI

/// The ⌘⇧5-style floating bar. Recording-only controls (audio, mic, webcam)
/// only appear in Record mode, and the webcam toggle only when enabled in config.
@MainActor
final class ToolbarPanel: NSPanel {
    struct Actions {
        var capture: () -> Void
        var cancel: () -> Void
        var openSettings: () -> Void
        var webcamChanged: (Bool) -> Void
    }

    private let actions: Actions
    private let mic = MicMonitor()
    private let systemAudio = SystemAudioMonitor()

    init(state: AppState, actions: Actions) {
        self.actions = actions
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above the region overlay (screenSaver level) so it stays clickable while selecting.
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = ToolbarView(state: state, mic: mic, systemAudio: systemAudio, actions: actions) { [weak self] size in
            self?.resize(to: size)
        }
        let host = NSHostingView(rootView: view)
        host.sizingOptions = [.intrinsicContentSize]
        contentView = host
    }

    override var canBecomeKey: Bool { true }

    override func orderOut(_ sender: Any?) {
        mic.stop()
        systemAudio.stop()
        super.orderOut(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        actions.cancel()
    }

    func present(on screen: NSScreen) {
        guard let host = contentView else { return }
        let size = host.fittingSize
        let vf = screen.visibleFrame
        setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.minY + 90, width: size.width, height: size.height), display: true)
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    /// Keeps the bar centered where it is when controls appear or disappear.
    private func resize(to size: CGSize) {
        guard size.width > 0, abs(size.width - frame.width) > 0.5 || abs(size.height - frame.height) > 0.5 else { return }
        setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY, width: size.width, height: size.height), display: true)
    }
}

private struct ToolbarView: View {
    @ObservedObject var state: AppState
    let mic: MicMonitor
    let systemAudio: SystemAudioMonitor
    let actions: ToolbarPanel.Actions
    let onSize: (CGSize) -> Void

    private var recording: Bool { state.session.action == .record }

    /// Meter only what a recording would actually capture.
    private var wantsMicLevel: Bool { recording && state.session.microphone }
    private var wantsSystemLevel: Bool { recording && state.session.systemAudio }

    private func syncMeters() {
        if wantsMicLevel { mic.start(deviceID: state.session.microphoneID) } else { mic.stop() }
        if wantsSystemLevel { systemAudio.start() } else { systemAudio.stop() }
    }

    private var webcamVisible: Bool { recording && state.config.webcam && state.session.webcamOn }

    var body: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "xmark.circle.fill", help: "Close (Esc)", action: actions.cancel)
                .foregroundStyle(.secondary)
            divider
            ForEach(CaptureMode.allCases, id: \.self) { mode in
                IconToggle(symbol: mode.symbol, help: mode.help, isOn: state.session.mode == mode) {
                    state.session.mode = mode
                }
            }
            divider
            ForEach(CaptureAction.allCases, id: \.self) { action in
                IconToggle(symbol: action.symbol, help: action.help, isOn: state.session.action == action) {
                    withAnimation(Design.animation) { state.session.action = action }
                }
            }
            divider
            if recording {
                LevelToggle(
                    meter: systemAudio.meter, onSymbol: "speaker.wave.2.fill", offSymbol: "speaker.slash",
                    help: "Record system audio", isOn: state.session.systemAudio, live: wantsSystemLevel
                ) { state.session.systemAudio.toggle() }
                LevelToggle(
                    meter: mic.meter, onSymbol: "mic.fill", offSymbol: "mic.slash",
                    help: "Record microphone", isOn: state.session.microphone, live: wantsMicLevel
                ) { state.session.microphone.toggle() }
                if state.config.webcam {
                    IconToggle(
                        symbol: state.session.webcamOn ? "video.fill" : "video.slash",
                        help: "Webcam bubble", isOn: state.session.webcamOn
                    ) { state.session.webcamOn.toggle() }
                }
            }
            IconToggle(
                symbol: state.session.showCursor ? "cursorarrow" : "cursorarrow.slash",
                help: "Show mouse cursor", isOn: state.session.showCursor
            ) { state.session.showCursor.toggle() }
            divider
            OptionsMenu(state: state, openSettings: actions.openSettings)
            Button(action: actions.capture) {
                Text(recording ? "Record" : "Capture")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(recording ? Color.red : Color.accentColor))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .reelSurface()
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
        .onAppear {
            syncMeters()
            actions.webcamChanged(webcamVisible)
        }
        .onChange(of: wantsMicLevel) { syncMeters() }
        .onChange(of: wantsSystemLevel) { syncMeters() }
        .onChange(of: state.session.microphoneID) { syncMeters() }
        .onChange(of: webcamVisible) { actions.webcamChanged(webcamVisible) }
    }

    private var divider: some View {
        Divider().frame(height: 22).padding(.horizontal, 3)
    }
}

private struct OptionsMenu: View {
    @ObservedObject var state: AppState
    let openSettings: () -> Void

    var body: some View {
        Menu {
            if state.session.action == .record {
                Section("Microphone") {
                    Picker("Microphone", selection: $state.session.microphoneID) {
                        Text("System Default").tag(String?.none)
                        ForEach(state.microphones, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(Optional(device.uniqueID))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            Section("Save To") {
                Button {
                    state.set("save-directory", "system")
                } label: {
                    check(state.config.saveDirectory == nil,
                          "System Location (\(SaveLocation.directory(for: .screenshot).lastPathComponent))")
                }
                Button {
                    state.set("save-directory", "~/Desktop")
                } label: { check(state.config.saveDirectory == "~/Desktop", "Desktop") }
                Button("Other Location…") { chooseSaveFolder(state) }
            }
            Divider()
            Button("Settings…", action: openSettings)
        } label: {
            Text("Options").font(.system(size: 13))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 6)
    }

    private func check(_ on: Bool, _ title: String) -> some View {
        on ? Label(title, systemImage: "checkmark") : Label(title, systemImage: "")
    }
}

@MainActor
func chooseSaveFolder(_ state: AppState) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Choose"
    NSApp.activate()
    if panel.runModal() == .OK, let url = panel.url {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
        state.set("save-directory", "\"\(path)\"")
    }
}

struct IconToggle: View {
    let symbol: String
    let help: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(isOn ? Color.primary.opacity(0.14) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Toggle whose glyph fills with green from the bottom as the audio gets louder.
/// Its own view so ~60 level updates a second don't re-render the whole toolbar.
private struct LevelToggle: View {
    @ObservedObject var meter: LevelMeter
    let onSymbol: String
    let offSymbol: String
    let help: String
    let isOn: Bool
    let live: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: isOn ? onSymbol : offSymbol)
                if isOn, live {
                    Image(systemName: onSymbol)
                        .foregroundStyle(.green)
                        .mask(alignment: .bottom) {
                            GeometryReader { geo in
                                Rectangle()
                                    .frame(height: geo.size.height * CGFloat(meter.level))
                                    .frame(maxHeight: .infinity, alignment: .bottom)
                            }
                        }
                        .animation(.linear(duration: 0.08), value: meter.level)
                }
            }
            .font(.system(size: 15))
            .frame(width: 30, height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(isOn ? Color.primary.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 24, height: 26)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private extension CaptureMode {
    var symbol: String {
        switch self {
        case .screen: "menubar.dock.rectangle"
        case .window: "macwindow"
        case .region: "rectangle.dashed"
        }
    }

    var help: String {
        switch self {
        case .screen: "Entire screen"
        case .window: "Selected window"
        case .region: "Selected region"
        }
    }
}

private extension CaptureAction {
    var symbol: String {
        switch self {
        case .screenshot: "camera"
        case .record: "record.circle"
        }
    }

    var help: String {
        switch self {
        case .screenshot: "Screenshot"
        case .record: "Record video"
        }
    }
}
