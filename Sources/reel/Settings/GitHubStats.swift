import Foundation
import SwiftUI

enum AppInfo {
    static let repo = "riensou/reel"
    static var repoURL: URL { URL(string: "https://github.com/\(repo)")! }
    static var issuesURL: URL { URL(string: "https://github.com/\(repo)/issues/new")! }
    static var owner: String { String(repo.split(separator: "/")[0]) }
    static var ownerAvatar: URL { URL(string: "https://github.com/\(owner).png?size=64")! }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

/// Star count and recent stargazers for the About page. Unauthenticated GitHub
/// API calls are limited to 60/hour, so results are cached for an hour.
@MainActor
final class GitHubStats: ObservableObject {
    static let shared = GitHubStats()

    struct Stargazer: Codable, Identifiable, Hashable {
        let login: String
        let avatar_url: URL
        let html_url: URL
        var id: String { login }
    }

    private struct Cache: Codable {
        var stars: Int?
        var recent: [Stargazer]
        var fetched: Date
    }

    @Published private(set) var stars: Int?
    @Published private(set) var recent: [Stargazer] = []
    @Published private(set) var loading = false

    private let key = "githubStats"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            stars = cache.stars
            recent = cache.recent
        }
    }

    func refreshIfNeeded() async {
        if let data = UserDefaults.standard.data(forKey: key),
           let cache = try? JSONDecoder().decode(Cache.self, from: data),
           Date.now.timeIntervalSince(cache.fetched) < 3600 { return }
        loading = stars == nil
        defer { loading = false }

        struct Repo: Decodable { let stargazers_count: Int }
        guard let repo: Repo = await get("https://api.github.com/repos/\(AppInfo.repo)") else { return }
        stars = repo.stargazers_count
        // The stargazers list is oldest-first; the last page has the newest.
        let perPage = 8
        let lastPage = max(1, (repo.stargazers_count + perPage - 1) / perPage)
        var newest: [Stargazer] = await get("https://api.github.com/repos/\(AppInfo.repo)/stargazers?per_page=\(perPage)&page=\(lastPage)") ?? []
        if newest.count < 5, lastPage > 1,
           let previous: [Stargazer] = await get("https://api.github.com/repos/\(AppInfo.repo)/stargazers?per_page=\(perPage)&page=\(lastPage - 1)") {
            newest = previous + newest
        }
        recent = Array(newest.reversed().prefix(8))
        if let data = try? JSONEncoder().encode(Cache(stars: stars, recent: recent, fetched: .now)) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func get<T: Decodable>(_ url: String) async -> T? {
        guard let url = URL(string: url) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// FreeFlow-style repo card: owner, repo link, live star count, a Star button,
/// and the faces of the latest stargazers.
struct GitHubCard: View {
    @ObservedObject private var stats = GitHubStats.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Avatar(url: AppInfo.ownerAvatar, size: 22)
                Button { openURL(AppInfo.repoURL) } label: {
                    Text(AppInfo.repo).font(.system(.caption, design: .monospaced).weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                Spacer()
                if stats.loading || stats.stars != nil {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption2)
                        if let n = stats.stars {
                            Text("\(n.formatted()) \(n == 1 ? "star" : "stars")")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.yellow.opacity(0.14)))
                }
                Button { openURL(AppInfo.repoURL) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "star")
                        Text("Star")
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.yellow.opacity(0.18)))
                }
                .buttonStyle(.plain)
            }
            if !stats.recent.isEmpty {
                Divider()
                HStack(spacing: 8) {
                    HStack(spacing: -6) {
                        ForEach(stats.recent) { s in
                            Button { openURL(s.html_url) } label: {
                                Avatar(url: s.avatar_url, size: 22)
                                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                            }
                            .buttonStyle(.plain)
                            .help(s.login)
                        }
                    }
                    Text("recently starred").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Design.hairline))
        .task { await stats.refreshIfNeeded() }
    }
}

private struct Avatar: View {
    let url: URL
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            if case .success(let image) = phase {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
