import AppKit
import ReelCore

/// Checks GitHub Releases for a newer version, at most once a day. No account,
/// no identifiers: one anonymous request to GitHub's public API.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Decodable {
        let tag_name: String
        let html_url: URL
    }

    @Published private(set) var available: Release?
    @Published private(set) var checking = false

    private let lastCheckKey = "lastUpdateCheck"
    private let announcedKey = "announcedUpdate"
    private var timer: Timer?

    /// Starts daily background checks (first one shortly after launch).
    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        Task {
            try? await Task.sleep(for: .seconds(10))
            checkIfDue()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func checkIfDue() {
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date.now.timeIntervalSince(last) > 86_400 else { return }
        Task { await check(userInitiated: false) }
    }

    /// - Parameter userInitiated: show a toast even when up to date.
    func check(userInitiated: Bool) async {
        checking = true
        defer { checking = false }
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppInfo.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data)
        else {
            if userInitiated { Toast.error("Couldn't check for updates") }
            return
        }
        UserDefaults.standard.set(Date.now, forKey: lastCheckKey)

        guard let latest = Version(release.tag_name), let current = Version(AppInfo.version), latest > current else {
            available = nil
            if userInitiated { Toast.info("reel \(AppInfo.version) is the latest version") }
            return
        }
        available = release
        // Announce each new version once; after that it waits quietly in the menu.
        if userInitiated || UserDefaults.standard.string(forKey: announcedKey) != release.tag_name {
            UserDefaults.standard.set(release.tag_name, forKey: announcedKey)
            Toast.info("reel \(latest) is available", icon: "arrow.down.circle.fill",
                       action: Toast.Action(title: "Download") { NSWorkspace.shared.open(release.html_url) })
        }
    }
}
