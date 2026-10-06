import AppKit
import ReelCore
import SwiftUI

/// reel's settings: a sidebar of sections and cards of controls, modelled on
/// FreeFlow's settings window. Every control reads from and writes to the
/// config file, so editing the file and using this window stay in sync.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let state: AppState
    private let actions: SettingsActions

    init(state: AppState, actions: SettingsActions) {
        self.state = state
        self.actions = actions
    }

    func show(tab: SettingsTab = .general) {
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "reel Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(state: state, actions: actions, tab: tab))
        window.center()
        window.setFrameAutosaveName("reel.settings")
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.window = nil }
        }
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

struct SettingsActions {
    var openConfig: () -> Void
    var revealConfig: () -> Void
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, recording, demo, permissions, about
    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .recording: "Recording"
        case .demo: "Demo Polish"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .recording: "record.circle"
        case .demo: "sparkles"
        case .permissions: "lock.shield"
        case .about: "info.circle"
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var state: AppState
    let actions: SettingsActions
    @State var tab: SettingsTab

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsTab.allCases) { t in
                    Button { tab = t } label: {
                        HStack(spacing: 8) {
                            Image(systemName: t.icon)
                                .font(.system(size: 13))
                                .frame(width: 16)
                            Text(t.title)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(tab == t ? Color.accentColor.opacity(0.15) : .clear))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 44) // clear the traffic lights
            .padding(.bottom, 10)
            .frame(width: 180)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(tab.title)
                            .font(.system(size: 22, weight: .semibold))
                            .padding(.bottom, 2)
                        if !state.configWarnings.isEmpty {
                            WarningCard(warnings: state.configWarnings, edit: actions.openConfig)
                        }
                        switch tab {
                        case .general: GeneralTab(state: state)
                        case .recording: RecordingTab(state: state)
                        case .demo: DemoTab(state: state)
                        case .permissions: PermissionsTab(state: state)
                        case .about: AboutTab(state: state, actions: actions)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 40)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                ConfigFooter(path: state.configFile.url, edit: actions.openConfig)
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.25))
        }
        .frame(minWidth: 720, minHeight: 520)
        .ignoresSafeArea()
    }
}

// MARK: - Building blocks

struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.06)))
    }
}

/// Title + one-line description on the left, control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
    }
}

private struct ConfigFooter: View {
    let path: URL
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text").foregroundStyle(.tertiary)
            Text((path.path as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            Button("Edit file…", action: edit)
                .buttonStyle(.link)
                .font(.system(size: 11))
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }
}

private struct WarningCard: View {
    let warnings: [Config.Warning]
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your config file has \(warnings.count == 1 ? "a problem" : "\(warnings.count) problems")")
                    .font(.system(size: 13, weight: .medium))
                ForEach(warnings.prefix(3), id: \.line) { w in
                    Text(w.description).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Edit", action: edit)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.25)))
    }
}

// MARK: - Config bindings

extension AppState {
    func binding(_ key: String, _ path: KeyPath<Config, Bool>) -> Binding<Bool> {
        Binding(get: { self.config[keyPath: path] }, set: { self.set(key, $0) })
    }

    func binding<E: RawRepresentable>(_ key: String, _ path: KeyPath<Config, E>) -> Binding<E> where E.RawValue == String {
        Binding(get: { self.config[keyPath: path] }, set: { self.set(key, $0.rawValue) })
    }

    func binding(_ key: String, _ path: KeyPath<Config, Int>) -> Binding<Int> {
        Binding(get: { self.config[keyPath: path] }, set: { self.set(key, String($0)) })
    }
}
