import Foundation

/// Memory and CPU per app, with the helper processes inside its bundle counted in.
struct AppUsage: Sendable {
    let app: ProcessSample
    let memory: UInt64
    let cpu: Double
    let processCount: Int

    /// Apps that host agent sessions or shells. Quitting one ends every session in it, so
    /// MacUnclog never suggests it, even when it is the biggest.
    static let agentHosts: Set<String> = [
        "com.anthropic.claudefordesktop", "com.openai.codex", "com.openai.chat",
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "com.cmuxterm.app", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode",
        "dev.zed.Zed", "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "com.exafunction.windsurf",
        "dev.warp.Warp-Preview", "com.google.android.studio",
    ]

    static func isAgentHost(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return agentHosts.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.")
    }

    /// Browsers whose tabs MacUnclog can list and close. Quitting one loses the user's place,
    /// so the browser gets a Tabs button instead of a Restart button.
    static let browsers: [String: Browser] = [
        "com.google.Chrome": .chromium, "com.google.Chrome.beta": .chromium, "com.google.Chrome.canary": .chromium,
        "company.thebrowser.dia": .chromium, "company.thebrowser.Browser": .chromium, "com.brave.Browser": .chromium,
        "com.microsoft.edgemac": .chromium, "com.vivaldi.Vivaldi": .chromium, "org.chromium.Chromium": .chromium,
        "com.apple.Safari": .safari, "com.apple.SafariTechnologyPreview": .safari,
    ]

    enum Browser: Sendable { case chromium, safari }

    var browser: Browser? { app.bundleIdentifier.flatMap { Self.browsers[$0] } }

    /// Regular apps the user may quit, biggest memory first. `excluding` holds the bundle IDs
    /// the user asked MacUnclog not to suggest.
    /// `hosts` are the processes agent sessions run under (`AgentLoad.hostPIDs`): an app with
    /// one of them among its processes is never offered, whatever its bundle ID.
    static func quittable(_ processes: [ProcessSample], excluding: Set<String> = [], hosts: Set<pid_t> = []) -> [AppUsage] {
        var groups: [String: [ProcessSample]] = [:]
        for process in processes {
            if let bundle = process.executablePath.flatMap(bundleRoot) { groups[bundle, default: []].append(process) }
        }
        return processes
            .filter { $0.isRegularApp && !ProcessPolicy.allowedActions(for: $0).isEmpty }
            .filter { !isAgentHost($0.bundleIdentifier) && !excluding.contains($0.bundleIdentifier ?? "") }
            .compactMap { app in
                let members = app.executablePath.flatMap(bundleRoot).flatMap { groups[$0] } ?? [app]
                guard !members.contains(where: { hosts.contains($0.pid) }) else { return nil }
                return AppUsage(app: app, memory: members.reduce(0) { $0 + $1.memoryBytes },
                                cpu: members.reduce(0) { $0 + $1.cpuPercent }, processCount: members.count)
            }
            .sorted { $0.memory > $1.memory }
    }

    /// "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/…" belongs to "/Applications/Slack.app".
    static func bundleRoot(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }
}

extension AppUsage: Identifiable {
    var id: pid_t { app.pid }
}
