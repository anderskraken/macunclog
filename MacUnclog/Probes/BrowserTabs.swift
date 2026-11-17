import AppKit
import OSLog

/// A tab in a running browser, read through the browser's scripting dictionary.
struct BrowserTab: Identifiable, Sendable, Hashable, Codable {
    let window: String
    /// Chromium's own tab ID. Safari has none, so it's empty there and `index` and `url`
    /// identify the tab.
    let tabID: String
    let index: Int
    let title: String
    let url: String

    var id: String { "\(window)/\(tabID.isEmpty ? String(index) : tabID)" }
    var host: String { URL(string: url)?.host() ?? url }
}

/// Lists and closes browser tabs with `osascript`, so macOS asks once per browser whether
/// MacUnclog may control it. Browsers don't say how much memory each tab uses.
enum BrowserTabs {
    enum Failure: Error, CustomStringConvertible {
        case notAllowed(String)
        case failed(String)

        var description: String {
            switch self {
            case .notAllowed(let app):
                String(localized: "MacUnclog isn’t allowed to control \(app). You can allow it in System Settings > Privacy & Security > Automation.")
            case .failed(let message): message
            }
        }
    }

    static let automationSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    static func list(_ usage: AppUsage) async throws(Failure) -> [BrowserTab] {
        guard let browser = usage.browser, let bundleID = usage.app.bundleIdentifier else { return [] }
        try await ensureRunning(usage)
        let output = try await run(browser == .safari ? safariList : chromiumList, [bundleID], app: usage.app.name)
        guard let tabs = try? JSONDecoder().decode([BrowserTab].self, from: Data(output.utf8)) else {
            throw .failed(String(localized: "\(usage.app.name) sent a tab list MacUnclog couldn’t read."))
        }
        return tabs
    }

    /// Closes each tab that is still where it was listed. Returns how many it closed.
    static func close(_ tabs: [BrowserTab], in usage: AppUsage) async throws(Failure) -> Int {
        guard let browser = usage.browser, let bundleID = usage.app.bundleIdentifier, !tabs.isEmpty,
              let data = try? JSONEncoder().encode(tabs)
        else { return 0 }
        try await ensureRunning(usage)
        let output = try await run(browser == .safari ? safariClose : chromiumClose,
                                   [bundleID, String(decoding: data, as: UTF8.self)], app: usage.app.name)
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Tabs whose address, without the part after #, appeared earlier in the list.
    static func duplicates(in tabs: [BrowserTab]) -> Set<String> {
        var seen: Set<String> = []
        var result: Set<String> = []
        for tab in tabs where !tab.url.isEmpty {
            let key = tab.url.split(separator: "#", maxSplits: 1).first.map(String.init) ?? tab.url
            if !seen.insert(key).inserted { result.insert(tab.id) }
        }
        return result
    }

    /// Talking to a browser that has quit would open it again.
    @MainActor
    private static func ensureRunning(_ usage: AppUsage) throws(Failure) {
        guard let app = NSRunningApplication(processIdentifier: usage.app.pid), !app.isTerminated else {
            throw .failed(String(localized: "\(usage.app.name) has quit."))
        }
    }

    private static func run(_ script: String, _ arguments: [String], app: String) async throws(Failure) -> String {
        // The first run waits for the user to answer macOS's permission prompt.
        let output = await Shell.run("/usr/bin/osascript", ["-l", "JavaScript", "-e", script] + arguments, timeout: .seconds(120))
        if output.stderr.contains("-1743") { throw .notAllowed(app) }
        if output.timedOut { throw .failed(String(localized: "\(app) didn’t answer. It may be busy. Try again in a moment.")) }
        guard output.succeeded else {
            log.error("osascript for \(app, privacy: .public) failed: \(output.stderr, privacy: .public)")
            throw .failed(String(localized: "MacUnclog couldn’t read the tabs in \(app)."))
        }
        return output.stdout
    }

    private static let log = Logger(subsystem: "io.github.anderskraken.macunclog", category: "tabs")

    // One Apple event per property for all windows at once: listing 300 tabs stays fast.
    private static let chromiumList = """
    function run(argv) {
      const app = Application(argv[0]);
      const windows = app.windows.id(), ids = app.windows.tabs.id();
      const titles = app.windows.tabs.title(), urls = app.windows.tabs.url();
      const out = [];
      windows.forEach((w, i) => ids[i].forEach((t, j) => out.push(
        { window: String(w), tabID: String(t), index: j, title: titles[i][j] || "", url: urls[i][j] || "" })));
      return JSON.stringify(out);
    }
    """

    private static let safariList = """
    function run(argv) {
      const app = Application(argv[0]);
      const out = [];
      app.windows().forEach(w => {
        let names, urls;
        try { names = w.tabs.name(); urls = w.tabs.url(); } catch (e) { return; }
        names.forEach((n, j) => out.push({ window: String(w.id()), tabID: "", index: j, title: n || "", url: urls[j] || "" }));
      });
      return JSON.stringify(out);
    }
    """

    // Closes from the highest index down, so earlier indexes stay valid.
    private static let chromiumClose = """
    function run(argv) {
      const app = Application(argv[0]), wanted = JSON.parse(argv[1]);
      let closed = 0;
      app.windows().forEach(w => {
        const ids = w.tabs.id().map(String), urls = w.tabs.url(), wid = String(w.id());
        // The address must match too: the list was read in several steps, and a tab can change.
        const targets = wanted.filter(t => t.window === wid)
          .map(t => ({ i: ids.indexOf(t.tabID), url: t.url }))
          .filter(t => t.i >= 0 && (urls[t.i] || "") === t.url).map(t => t.i);
        targets.sort((a, b) => b - a).forEach(i => { try { w.tabs[i].close(); closed++; } catch (e) {} });
      });
      return String(closed);
    }
    """

    private static let safariClose = """
    function run(argv) {
      const app = Application(argv[0]), wanted = JSON.parse(argv[1]);
      let closed = 0;
      app.windows().forEach(w => {
        let urls;
        try { urls = w.tabs.url(); } catch (e) { return; }
        const wid = String(w.id());
        const targets = wanted.filter(t => t.window === wid && (urls[t.index] || "") === t.url).map(t => t.index);
        targets.sort((a, b) => b - a).forEach(i => { try { w.tabs[i].close(); closed++; } catch (e) {} });
      });
      return String(closed);
    }
    """
}
