import AppKit
import ReelCore
import SwiftUI

/// The ⌘⇧5-style floating bar, with audio/mic/cursor toggles surfaced right on it
/// instead of buried in a menu.
@MainActor
final class ToolbarPanel: NSPanel {
    var onCancel: (() -> Void)?
    private let mic = MicMonitor()
    private let systemAudio = SystemAudioMonitor()

    init(state: AppState, onCapture: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: ToolbarView(state: state, mic: mic, systemAudio: systemAudio, onCapture: onCapture, onCancel: onCancel))
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
        onCancel?()
    }

    func present(on screen: NSScreen) {
        guard let host = contentView else { return }
        let size = host.fittingSize
        let vf = screen.visibleFrame
        setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.minY + 90, width: size.width, height: size.height), display: true)
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }
}

private struct ToolbarView: View {
    @ObservedObject var state: AppState
    let mic: MicMonitor
    let systemAudio: SystemAudioMonitor
    let onCapture: () -> Void
    let onCancel: () -> Void

    /// Meter only what a recording would actually capture.
    private var wantsMicLevel: Bool {
        state.prefs.action == .record && state.prefs.options.microphone
    }

    private var wantsSystemLevel: Bool {
        state.prefs.action == .record && state.prefs.options.systemAudio
    }

    private func syncMeters() {
        if wantsMicLevel { mic.start(deviceID: state.prefs.options.microphoneID) } else { mic.stop() }
        if wantsSystemLevel { systemAudio.start() } else { systemAudio.stop() }
    }

    var body: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "xmark.circle.fill", help: "Close (Esc)", action: onCancel)
                .foregroundStyle(.secondary)
            divider
            ForEach(CaptureMode.allCases, id: \.self) { mode in
                IconToggle(symbol: mode.symbol, help: mode.help, isOn: state.prefs.mode == mode) {
                    state.prefs.mode = mode
                }
            }
            divider
            ForEach(CaptureAction.allCases, id: \.self) { action in
                IconToggle(symbol: action.symbol, help: action.help, isOn: state.prefs.action == action) {
                    state.prefs.action = action
                }
            }
            divider
            LevelToggle(
                meter: systemAudio.meter, onSymbol: "speaker.wave.2.fill", offSymbol: "speaker.slash",
                help: "Record system audio", isOn: state.prefs.options.systemAudio, live: wantsSystemLevel
            ) { state.prefs.options.systemAudio.toggle() }
                .disabled(state.prefs.action == .screenshot)
            LevelToggle(
                meter: mic.meter, onSymbol: "mic.fill", offSymbol: "mic.slash",
                help: "Record microphone", isOn: state.prefs.options.microphone, live: wantsMicLevel
            ) { state.prefs.options.microphone.toggle() }
                .disabled(state.prefs.action == .screenshot)
            IconToggle(
                symbol: state.prefs.options.cursor.show ? "cursorarrow" : "cursorarrow.slash",
                help: "Show mouse cursor", isOn: state.prefs.options.cursor.show
            ) { state.prefs.options.cursor.show.toggle() }
            divider
            OptionsMenu(state: state)
            Button(action: onCapture) {
                Text(state.prefs.action == .record ? "Record" : "Capture")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(state.prefs.action == .record ? Color.red : Color.accentColor))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .onAppear(perform: syncMeters)
        .onChange(of: wantsMicLevel) { syncMeters() }
        .onChange(of: wantsSystemLevel) { syncMeters() }
        .onChange(of: state.prefs.options.microphoneID) { syncMeters() }
    }

    private var divider: some View {
        Divider().frame(height: 22).padding(.horizontal, 3)
    }
}

private struct OptionsMenu: View {
    @ObservedObject var state: AppState

    var body: some View {
        Menu {
            Section("Microphone") {
                Picker("Microphone", selection: $state.prefs.options.microphoneID) {
                    Text("System Default").tag(String?.none)
                    ForEach(state.microphones, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(Optional(device.uniqueID))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("Frame Rate") {
                Picker("Frame Rate", selection: $state.prefs.options.fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("Save To") {
                Button {
                    state.prefs.saveDirectory = nil
                } label: {
                    check(state.prefs.saveDirectory == nil,
                          "System Location (\(SaveLocation.directory(for: .screenshot).lastPathComponent))")
                }
                Button {
                    state.prefs.saveDirectory = "~/Desktop"
                } label: { check(state.prefs.saveDirectory == "~/Desktop", "Desktop") }
                Button("Other Location…") { chooseFolder() }
            }
            Section {
                Toggle("Show Floating Thumbnail", isOn: $state.prefs.showThumbnail)
            }
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

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            state.prefs.saveDirectory = url.path
        }
    }
}

private struct IconToggle: View {
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
