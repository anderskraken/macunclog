import Foundation

/// simslim (github.com/MobAI-App/simslim, MIT) turns off the background services a
/// simulator doesn't need for development, which cuts its memory to about a quarter.
/// MacUnclog uses the user's own copy of the command line tool when it's installed.
enum SimSlim {
    static let installCommand = "brew install mobai-app/tap/simslim"
    static let project = URL(string: "https://github.com/MobAI-App/simslim")!

    static var executable: String? { Shell.which("simslim") }

    /// simslim manages about 170 services per runtime. A simulator with at least this many
    /// turned off counts as slim. Read from the file launchd_sim keeps per device, so it
    /// costs no process.
    static let slimThreshold = 80

    static func disabledCount(udid: String, root: String = "/private/var/tmp") -> Int {
        let file = "\(root)/com.apple.CoreSimulator.SimDevice.\(udid)/disabled.plist"
        guard let entries = NSDictionary(contentsOfFile: file) as? [String: Any] else { return 0 }
        return entries.values.filter { ($0 as? Bool) == true || ($0 as? NSNumber)?.boolValue == true }.count
    }

    /// Which of these simulators are slim, or nil when simslim isn't installed.
    static func slimUDIDs(_ udids: some Sequence<String>) -> Set<String>? {
        guard executable != nil else { return nil }
        return Set(udids.filter { disabledCount(udid: $0) >= slimThreshold })
    }

    /// Slims a booted simulator in place, without a reboot, so whoever uses it keeps it.
    /// On runtimes that keep the change, its next boot comes up slim too. Returns a problem
    /// to show, or nil.
    static func slim(udid: String) async -> String? {
        guard executable != nil else { return String(localized: "simslim isn’t installed.") }
        let output = await Shell.run("simslim", ["on", udid, "--no-reboot"], timeout: .seconds(600))
        if output.succeeded { return nil }
        if output.timedOut { return String(localized: "simslim took more than 10 minutes and was stopped.") }
        let message = output.stderr.split(separator: "\n").last.map(String.init) ?? ""
        return message.isEmpty ? String(localized: "simslim couldn’t slim the simulator.") : message
    }
}
