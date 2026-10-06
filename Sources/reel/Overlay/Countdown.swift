import AppKit
import SwiftUI

/// 3…2…1 over the capture area. Click to skip, Esc to cancel.
/// Returns true to start recording, false if cancelled.
@MainActor
final class Countdown {
    private var panel: KeyPanel?
    private var continuation: CheckedContinuation<Bool, Never>?

    func run(seconds: Int, over rect: NSRect) async -> Bool {
        guard seconds > 0 else { return true }
        return await withCheckedContinuation { cont in
            continuation = cont
            let model = CountdownModel(value: seconds)
            let size = NSSize(width: 160, height: 160)
            let panel = KeyPanel(contentRect: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                                     width: size.width, height: size.height))
            panel.onCancel = { [weak self] in self?.finish(false) }
            panel.contentView = NSHostingView(rootView: CountdownView(model: model) { [weak self] in self?.finish(true) })
            self.panel = panel
            panel.alphaValue = 0
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }

            Task { [weak self] in
                for n in stride(from: seconds, to: 0, by: -1) {
                    guard self?.continuation != nil else { return }
                    withAnimation(Design.animation) { model.value = n }
                    try? await Task.sleep(for: .seconds(1))
                }
                self?.finish(true)
            }
        }
    }

    private func finish(_ go: Bool) {
        guard let cont = continuation else { return }
        continuation = nil
        panel?.orderOut(nil)
        panel = nil
        cont.resume(returning: go)
    }
}

@MainActor
private final class CountdownModel: ObservableObject {
    @Published var value: Int
    init(value: Int) { self.value = value }
}

private struct CountdownView: View {
    @ObservedObject var model: CountdownModel
    let onSkip: () -> Void

    var body: some View {
        ZStack {
            Circle().fill(.regularMaterial)
            Circle().strokeBorder(Design.hairline)
            Text("\(model.value)")
                .font(.system(size: 64, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .id(model.value)
                .transition(Design.reduceMotion ? .opacity : .scale(scale: 1.3).combined(with: .opacity))
        }
        .frame(width: 120, height: 120)
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSkip)
        .help("Click to start now · Esc to cancel")
    }
}

/// Borderless panel that can take key status so Esc works.
final class KeyPanel: NSPanel {
    var onCancel: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
