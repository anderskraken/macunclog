import Foundation

enum ProcessAction: Sendable, Hashable {
    case quit, forceQuit, pause, resume
}

/// What MacUnclog may do to a process. Anything owned by another user, part of macOS,
/// or needed to keep the session alive gets no actions at all.
enum ProcessPolicy {
    static let protectedNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "Dock", "SystemUIServer",
        "ControlCenter", "Finder", "coreaudiod", "NotificationCenter", "TextInputMenuAgent",
        "mds", "mds_stores", "mdworker", "mdworker_shared", "backupd", "softwareupdated",
        "cfprefsd", "distnoted", "UserEventAgent", "securityd", "trustd", "opendirectoryd",
    ]

    /// Where macOS keeps its own agents and daemons. Command-line tools in /bin and
    /// /usr/bin are left actionable, since a runaway one was started by the user.
    private static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/", "/private/var/"]

    static func allowedActions(for process: ProcessSample, ownPID: pid_t = getpid()) -> [ProcessAction] {
        guard process.isOwnedByUser, process.pid > 1, process.pid != ownPID,
              process.state != .zombie, !protectedNames.contains(process.name)
        else { return [] }

        if process.isRegularApp {
            return [.quit, .forceQuit]
        }
        if let path = process.executablePath, systemPrefixes.contains(where: path.hasPrefix) {
            return []
        }
        return [.quit, .forceQuit, process.state == .stopped ? .resume : .pause]
    }
}

/// Plain-language explanations for processes people meet in Activity Monitor.
enum ProcessKnowledge {
    struct Entry: Sendable {
        let explanation: String
        let passesOnItsOwn: Bool
    }

    private static let table: [(prefix: String, entry: Entry)] = [
        ("mds", Entry(explanation: String(localized: "Spotlight is indexing your files. It will finish on its own."), passesOnItsOwn: true)),
        ("mdworker", Entry(explanation: String(localized: "Spotlight is reading files to index them. It will finish on its own."), passesOnItsOwn: true)),
        ("kernel_task", Entry(explanation: String(localized: "macOS is holding back the CPU to cool your Mac down."), passesOnItsOwn: true)),
        ("WindowServer", Entry(explanation: String(localized: "Draws everything on screen. Many windows, displays and animations mean a high load."), passesOnItsOwn: false)),
        ("photoanalysisd", Entry(explanation: String(localized: "Photos is analysing your library in the background."), passesOnItsOwn: true)),
        ("mediaanalysisd", Entry(explanation: String(localized: "macOS is analysing photos and videos in the background."), passesOnItsOwn: true)),
        ("backupd", Entry(explanation: String(localized: "Time Machine is backing up."), passesOnItsOwn: true)),
        ("softwareupdated", Entry(explanation: String(localized: "macOS is downloading or preparing an update."), passesOnItsOwn: true)),
        ("SourceKitService", Entry(explanation: String(localized: "Xcode is indexing your code."), passesOnItsOwn: true)),
        ("XCBBuildService", Entry(explanation: String(localized: "Xcode is building a project."), passesOnItsOwn: true)),
        ("swift-frontend", Entry(explanation: String(localized: "The Swift compiler is building code."), passesOnItsOwn: true)),
        ("com.apple.Virtualization", Entry(explanation: String(localized: "A virtual machine, often Docker or another VM."), passesOnItsOwn: false)),
        ("node", Entry(explanation: String(localized: "A Node.js program, often a dev server, Metro or a build tool."), passesOnItsOwn: false)),
        ("java", Entry(explanation: String(localized: "A Java program, such as Gradle or the Firebase emulators."), passesOnItsOwn: false)),
        ("cargo", Entry(explanation: String(localized: "Cargo is building a Rust project."), passesOnItsOwn: true)),
        ("rustc", Entry(explanation: String(localized: "The Rust compiler is building code."), passesOnItsOwn: true)),
        ("launchd_sim", Entry(explanation: String(localized: "An iOS simulator is running."), passesOnItsOwn: false)),
        ("Google Chrome Helper", Entry(explanation: String(localized: "A tab or extension in Chrome."), passesOnItsOwn: false)),
        ("Simulator", Entry(explanation: String(localized: "The iOS Simulator app."), passesOnItsOwn: false)),
    ]

    static func entry(for name: String) -> Entry? {
        table.first { name.hasPrefix($0.prefix) }?.entry
    }
}
