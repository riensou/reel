import AppKit
import ReelCore
import SwiftUI

/// First-run window: what reel is, the shortcut, and the one permission it
/// needs. Shown on first launch, and again if Screen Recording access is missing.
@MainActor
final class WelcomeWindowController {
    private var window: NSWindow?
    private let state: AppState
    private let onDone: () -> Void
    private let openSettings: () -> Void

    init(state: AppState, onDone: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.state = state
        self.onDone = onDone
        self.openSettings = openSettings
    }

    func show() {
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WelcomeView(
            state: state,
            done: { [weak self] in self?.finish() },
            openSettings: { [weak self] in self?.openSettings() }
        ))
        window.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.state.session.onboarded = true
                self?.window = nil
            }
        }
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        state.session.onboarded = true
        window?.close()
        onDone()
    }
}

private struct WelcomeView: View {
    @ObservedObject var state: AppState
    let done: () -> Void
    let openSettings: () -> Void
    @State private var granted = CGPreflightScreenCaptureAccess()
    @State private var asked = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)
                Text("Welcome to reel")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Screenshots and screen recordings from your menu bar.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 44)
            .padding(.bottom, 24)

            VStack(spacing: 12) {
                Step(number: 1, title: "Open the toolbar") {
                    HStack(spacing: 6) {
                        ForEach(Array(state.config.hotkey.symbols.enumerated()), id: \.offset) { _, key in
                            Keycap(String(key))
                        }
                        Spacer()
                        Button("Change…", action: openSettings)
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                    }
                    Text("Or click the ⦿ icon in the menu bar.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Step(number: 2, title: "Allow screen recording") {
                    HStack {
                        if granted {
                            Label("Allowed", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.system(size: 13, weight: .medium))
                        } else {
                            Text("macOS needs your OK before reel can capture the screen.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button(asked ? "Open Settings" : "Allow…") { requestAccess() }
                                .controlSize(.regular)
                        }
                    }
                    if asked && !granted {
                        Text("Turn on reel in Privacy & Security → Screen & System Audio Recording. macOS may ask you to quit and reopen reel.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 16)

            Button(action: done) {
                Text("Get Started")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .frame(width: 460, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            // Reflect the grant as soon as it happens in System Settings.
            while !Task.isCancelled {
                granted = CGPreflightScreenCaptureAccess()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func requestAccess() {
        if !asked {
            asked = true
            // Shows the system prompt the first time; afterwards it does nothing.
            if CGRequestScreenCaptureAccess() { granted = true }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct Step<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 14, weight: .semibold))
                content
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.06)))
    }
}

private struct Keycap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 15, weight: .medium, design: .rounded))
            .frame(minWidth: 30, minHeight: 28)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            .shadow(color: .black.opacity(0.15), radius: 0, y: 1)
    }
}
