import Foundation
import Observation

/// A release version such as 1.1 or 1.0.2. The leading "v" of a tag is optional, and
/// missing parts count as zero, so 1.1 and 1.1.0 are the same version.
struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        var text = Substring(text.trimmingCharacters(in: .whitespaces))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        let numbers = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, !numbers.contains(nil) else { return nil }
        parts = numbers.compactMap { $0 }
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    private static func padded(_ a: AppVersion, _ b: AppVersion) -> ([Int], [Int]) {
        let count = max(a.parts.count, b.parts.count)
        func pad(_ parts: [Int]) -> [Int] { parts + Array(repeating: 0, count: count - parts.count) }
        return (pad(a.parts), pad(b.parts))
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool {
        let (a, b) = padded(a, b)
        return a == b
    }

    static func < (a: AppVersion, b: AppVersion) -> Bool {
        let (a, b) = padded(a, b)
        return a.lexicographicallyPrecedes(b)
    }

    /// CFBundleShortVersionString of the running app.
    static let running = AppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
}

/// The newest published release, as GitHub's releases API describes it.
struct Release: Codable, Sendable, Equatable {
    let tag: String
    let page: URL

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name"
        case page = "html_url"
    }

    var version: AppVersion? { AppVersion(tag) }
    /// "1.1" for the tag v1.1.
    var name: String { version?.description ?? tag }

    /// Reads a response from /releases/latest. The page must be on github.com, since
    /// the Download button opens it.
    static func parse(_ data: Data) throws -> Release {
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              release.version != nil,
              release.page.scheme == "https", release.page.host() == "github.com"
        else { throw UpdateError.unreadableRelease }
        return release
    }

    func isNewer(than version: AppVersion?) -> Bool {
        guard let mine = self.version, let version else { return false }
        return mine > version
    }
}

enum UpdateError: LocalizedError {
    case status(Int)
    case unreadableRelease

    var errorDescription: String? {
        switch self {
        case .status(let code): String(localized: "GitHub answered with status \(code).")
        case .unreadableRelease: String(localized: "GitHub sent a release MacUnclog can’t read.")
        }
    }
}

/// Asks GitHub for the newest release, at most once a day. It only tells; downloading
/// and installing are up to the user.
@MainActor
@Observable
final class UpdateChecker {
    enum Outcome: Equatable {
        case available(Release)
        case upToDate
        case failed(String)
    }

    private static let endpoint = URL(string: "https://api.github.com/repos/anderskraken/macunclog/releases/latest")!
    private static let interval: TimeInterval = 86_400

    /// The newest release found, kept between launches so the notice stays until the user updates.
    private(set) var latest: Release? = UserDefaults.standard.data(forKey: "latestRelease")
        .flatMap { try? JSONDecoder().decode(Release.self, from: $0) } {
        didSet { UserDefaults.standard.set(latest.flatMap { try? JSONEncoder().encode($0) }, forKey: "latestRelease") }
    }
    /// When GitHub last answered.
    private(set) var lastCheck = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date {
        didSet { UserDefaults.standard.set(lastCheck, forKey: "lastUpdateCheck") }
    }
    private(set) var isChecking = false
    private(set) var failure: String?

    var available: Release? {
        guard let latest, latest.isNewer(than: .running) else { return nil }
        return latest
    }

    private var loop: Task<Void, Never>?

    /// Checks once a day while `isEnabled` says so. The app can sit in the menu bar for
    /// weeks, so it looks every hour whether a day has passed.
    func start(isEnabled: @escaping @MainActor () -> Bool) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled, let self {
                if isEnabled(), Date.now.timeIntervalSince(self.lastCheck ?? .distantPast) >= Self.interval {
                    _ = await self.check()
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    @discardableResult
    func check() async -> Outcome {
        isChecking = true
        defer { isChecking = false }
        do {
            latest = try await Self.fetchLatest()
            lastCheck = .now
            failure = nil
            return available.map(Outcome.available) ?? .upToDate
        } catch {
            failure = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

    /// nil when the repository has no releases yet.
    private static func fetchLatest() async throws -> Release? {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return try Release.parse(data)
        case 404: return nil
        case let code: throw UpdateError.status(code)
        }
    }
}
