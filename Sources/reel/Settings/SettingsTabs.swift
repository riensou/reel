@preconcurrency import AVFoundation
import AppKit
import ReelCore
import SwiftUI

// MARK: - General

struct GeneralTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        SettingsCard("App", icon: "power") {
            SettingRow(title: "Launch at login", detail: "Start reel in the menu bar when you log in.") {
                Toggle("", isOn: state.binding("launch-at-login", \.launchAtLogin)).labelsHidden().toggleStyle(.switch)
            }
            Divider()
            SettingRow(title: "Toolbar shortcut", detail: "Opens the capture toolbar; stops a recording in progress.") {
                ShortcutField(combo: state.config.hotkey) { state.set("hotkey", $0.description) }
            }
        }
        SettingsCard("Saving", icon: "folder") {
            SettingRow(title: "Save to", detail: (state.saveDirectory(for: .screenshot).path as NSString).abbreviatingWithTildeInPath) {
                Menu {
                    Button("System Screenshot Location") { state.set("save-directory", "system") }
                    Button("Desktop") { state.set("save-directory", "~/Desktop") }
                    Divider()
                    Button("Choose…") { chooseSaveFolder(state) }
                } label: {
                    Text(saveLabel)
                }
                .fixedSize()
            }
            Divider()
            SettingRow(title: "Floating thumbnail", detail: "Preview in the corner before the file is saved. Drag it into any app.") {
                Toggle("", isOn: state.binding("thumbnail", \.thumbnail)).labelsHidden().toggleStyle(.switch)
            }
            if state.config.thumbnail {
                SettingRow(title: "Save after") {
                    Picker("", selection: Binding(
                        get: { Int(state.config.thumbnailDuration) },
                        set: { state.set("thumbnail-duration", String($0)) }
                    )) {
                        Text("3s").tag(3)
                        Text("5s").tag(5)
                        Text("10s").tag(10)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
        }
    }

    private var saveLabel: String {
        switch state.config.saveDirectory {
        case nil: "System Location"
        case "~/Desktop": "Desktop"
        case let p?: URL(fileURLWithPath: (p as NSString).expandingTildeInPath).lastPathComponent
        }
    }
}

/// Click, then press a shortcut. Esc cancels.
struct ShortcutField: View {
    let combo: KeyCombo
    let onChange: (KeyCombo) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Type shortcut…" : combo.symbols)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .frame(minWidth: 96)
                .padding(.vertical, 4)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(recording ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(recording ? Color.accentColor : Design.hairline))
        }
        .buttonStyle(.plain)
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil } // Esc
            var mods: KeyCombo.Modifiers = []
            let f = event.modifierFlags
            if f.contains(.command) { mods.insert(.command) }
            if f.contains(.shift) { mods.insert(.shift) }
            if f.contains(.option) { mods.insert(.option) }
            if f.contains(.control) { mods.insert(.control) }
            let combo = KeyCombo(keyCode: Int(event.keyCode), modifiers: mods)
            guard !mods.isEmpty, KeyCombo.name(forKeyCode: combo.keyCode) != nil else {
                NSSound.beep()
                return nil
            }
            onChange(combo)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Recording

struct RecordingTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        SettingsCard("Video", icon: "film") {
            SettingRow(title: "Format", detail: "MP4 plays everywhere; MOV is QuickTime's native format.") {
                Picker("", selection: state.binding("video-format", \.videoFormat)) {
                    Text("MP4").tag(VideoFormat.mp4)
                    Text("MOV").tag(VideoFormat.mov)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            Divider()
            SettingRow(title: "Codec", detail: "Auto uses H.264 for compatibility, HEVC for screens wider than 4K.") {
                Picker("", selection: state.binding("video-codec", \.videoCodec)) {
                    Text("Auto").tag(VideoCodec.auto)
                    Text("H.264").tag(VideoCodec.h264)
                    Text("HEVC").tag(VideoCodec.hevc)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            Divider()
            SettingRow(title: "Frame rate") {
                Picker("", selection: state.binding("fps", \.fps)) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
        }
        SettingsCard("Audio", icon: "waveform") {
            SettingRow(title: "Merge audio tracks",
                       detail: "Mix mic and system audio into one track. Most players only play the first track.") {
                Toggle("", isOn: state.binding("merge-audio-tracks", \.mergeAudioTracks)).labelsHidden().toggleStyle(.switch)
            }
            Divider()
            SettingRow(title: "Microphone") {
                Picker("", selection: $state.session.microphoneID) {
                    Text("System Default").tag(String?.none)
                    ForEach(state.microphones, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                }
                .labelsHidden().fixedSize()
            }
        }
        SettingsCard("While Recording", icon: "record.circle") {
            SettingRow(title: "Countdown", detail: "3-2-1 before recording starts. Click to skip, Esc to cancel.") {
                Picker("", selection: state.binding("countdown", \.countdown)) {
                    Text("Off").tag(0)
                    Text("3s").tag(3)
                    Text("5s").tag(5)
                    Text("10s").tag(10)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            Divider()
            SettingRow(title: "Recording border",
                       detail: "Outline the recorded region or window. It's never in the video.") {
                Toggle("", isOn: state.binding("recording-border", \.recordingBorder)).labelsHidden().toggleStyle(.switch)
            }
        }
    }
}

// MARK: - Demo polish

struct DemoTab: View {
    @ObservedObject var state: AppState
    @State private var zoom: Double = 1.8
    @State private var axTrusted = KeystrokeHUD.hasPermission

    var body: some View {
        SettingsCard("Keystrokes", icon: "keyboard") {
            SettingRow(title: "Show keystrokes",
                       detail: "Shortcuts shows ⌘/⌃/⌥ combos and keys like ↩; All also shows typing. Password fields are never shown.") {
                Picker("", selection: state.binding("show-keystrokes", \.showKeystrokes)) {
                    Text("Off").tag(Config.Keystrokes.off)
                    Text("Shortcuts").tag(Config.Keystrokes.shortcuts)
                    Text("All").tag(Config.Keystrokes.all)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            if state.config.showKeystrokes != .off && !axTrusted {
                PermissionHint(text: "Needs Accessibility permission") {
                    KeystrokeHUD.requestPermission()
                }
            }
        }
        .task {
            while !Task.isCancelled {
                axTrusted = KeystrokeHUD.hasPermission
                try? await Task.sleep(for: .seconds(1))
            }
        }
        SettingsCard("Webcam", icon: "video") {
            SettingRow(title: "Webcam bubble",
                       detail: "Adds a camera button to the toolbar. Drag the bubble to any corner; right-click it for options.") {
                Toggle("", isOn: Binding(
                    get: { state.config.webcam },
                    set: { on in
                        state.set("webcam", on)
                        if on { state.session.webcamOn = true }
                    }
                )).labelsHidden().toggleStyle(.switch)
            }
            if state.config.webcam {
                Divider()
                SettingRow(title: "Size") {
                    Picker("", selection: state.binding("webcam-size", \.webcamSize)) {
                        ForEach(Config.WebcamSize.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                SettingRow(title: "Shape") {
                    Picker("", selection: state.binding("webcam-shape", \.webcamShape)) {
                        Text("Circle").tag(Config.WebcamShape.circle)
                        Text("Rounded").tag(Config.WebcamShape.rounded)
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                SettingRow(title: "Camera") {
                    Picker("", selection: $state.session.cameraID) {
                        Text("Default").tag(String?.none)
                        ForEach(state.cameras, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
        SettingsCard("After Recording", icon: "wand.and.stars") {
            SettingRow(title: "Auto-zoom", detail: "Smoothly zoom in where you click, then back out.") {
                Toggle("", isOn: state.binding("auto-zoom", \.autoZoom)).labelsHidden().toggleStyle(.switch)
            }
            if state.config.autoZoom {
                SettingRow(title: "Zoom amount") {
                    HStack(spacing: 8) {
                        Slider(value: $zoom, in: 1.2...3, step: 0.1) { editing in
                            if !editing { state.set("auto-zoom-scale", String(format: "%.1f", zoom)) }
                        }
                        .frame(width: 160)
                        Text(String(format: "%.1f×", zoom))
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
            Divider()
            SettingRow(title: "Smooth cursor", detail: "Redraw the cursor gliding along a smoothed path.") {
                Toggle("", isOn: state.binding("smooth-cursor", \.smoothCursor)).labelsHidden().toggleStyle(.switch)
            }
            if state.config.autoZoom || state.config.smoothCursor {
                Text("These re-encode the video after you stop, so saving takes a few extra seconds.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { zoom = state.config.autoZoomScale }
        .onChange(of: state.config.autoZoomScale) { zoom = state.config.autoZoomScale }
    }
}

private struct PermissionHint: View {
    let text: String
    let grant: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Text(text).font(.system(size: 12))
            Spacer()
            Button("Grant Access…", action: grant).controlSize(.small)
        }
    }
}

// MARK: - Permissions

struct PermissionsTab: View {
    @ObservedObject var state: AppState
    @State private var tick = 0

    var body: some View {
        SettingsCard("Privacy", icon: "lock.shield") {
            let _ = tick
            PermissionRow(name: "Screen & System Audio Recording", why: "Required to capture anything.",
                          granted: CGPreflightScreenCaptureAccess(), pane: "Privacy_ScreenCapture") {
                CGRequestScreenCaptureAccess()
            }
            if state.session.microphone {
                Divider()
                PermissionRow(name: "Microphone", why: "For recording your voice.",
                              granted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                              pane: "Privacy_Microphone") {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in }
                }
            }
            if state.config.webcam {
                Divider()
                PermissionRow(name: "Camera", why: "For the webcam bubble.",
                              granted: AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                              pane: "Privacy_Camera") {
                    AVCaptureDevice.requestAccess(for: .video) { _ in }
                }
            }
            if state.config.showKeystrokes != .off {
                Divider()
                PermissionRow(name: "Accessibility", why: "For showing keystrokes.",
                              granted: KeystrokeHUD.hasPermission, pane: "Privacy_Accessibility") {
                    KeystrokeHUD.requestPermission()
                }
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                tick += 1
            }
        }
        Text("Only the permissions your enabled features need are listed.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}

private struct PermissionRow: View {
    let name: String
    let why: String
    let granted: Bool
    let pane: String
    let request: () -> Void

    var body: some View {
        SettingRow(title: name, detail: why) {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            } else {
                Button("Grant…") {
                    request()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

// MARK: - About

struct AboutTab: View {
    @ObservedObject var state: AppState
    let actions: SettingsActions
    @Environment(\.openURL) private var openURL

    private var diagnostics: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "Apple silicon"
        #else
        let arch = "Intel"
        #endif
        return "reel \(AppInfo.version)\nmacOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(arch))"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            VStack(spacing: 2) {
                Text("reel")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("An open-source screen recorder for macOS")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("v\(AppInfo.version)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            GitHubCard()
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)

        SettingsCard("Configuration", icon: "doc.text") {
            Text("Every setting lives in a plain-text file, like ghostty or vim. Edit it in any editor; reel reloads it when you save.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text((state.configFile.url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button("Open", action: actions.openConfig)
                Button("Reveal", action: actions.revealConfig)
            }
            .padding(8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        }

        SettingsCard("Feedback", icon: "bubble.left.and.text.bubble.right") {
            SettingRow(title: "Found a bug or have an idea?", detail: "Issues and pull requests are welcome.") {
                Button("Open an Issue") { openURL(AppInfo.issuesURL) }
            }
            Divider()
            SettingRow(title: "Build", detail: diagnostics) {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagnostics, forType: .string)
                    Toast.info("Copied build info")
                }
            }
        }
    }
}
