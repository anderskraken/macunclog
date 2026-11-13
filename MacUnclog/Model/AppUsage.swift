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
    ]

    /// Regular apps the user may quit, biggest memory first.
    static func quittable(_ processes: [ProcessSample]) -> [AppUsage] {
        var groups: [String: [ProcessSample]] = [:]
        for process in processes {
            if let bundle = process.executablePath.flatMap(bundleRoot) { groups[bundle, default: []].append(process) }
        }
        return processes
            .filter { $0.isRegularApp && !ProcessPolicy.allowedActions(for: $0).isEmpty }
            .filter { !agentHosts.contains($0.bundleIdentifier ?? "") }
            .map { app in
                let members = app.executablePath.flatMap(bundleRoot).flatMap { groups[$0] } ?? [app]
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
