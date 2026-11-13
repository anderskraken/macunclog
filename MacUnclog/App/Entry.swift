import AppKit

/// One binary, three faces: the app, the launchd agent (`--agent`) and a small
/// command line for checking what a cleanup would do (`--diagnose`, `--scan`).
@main
enum Entry {
    static func main() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            NSApplication.shared.run()
            return
        }
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let mode = arguments.first, mode.hasPrefix("--"), CommandLineTool.modes.contains(mode) else {
            MacUnclogApp.main()
            return
        }
        Task {
            let status = await CommandLineTool.run(mode: mode, arguments: Array(arguments.dropFirst()))
            exit(status)
        }
        dispatchMain()
    }
}

enum CommandLineTool {
    static let modes: Set<String> = ["--agent", "--diagnose", "--scan", "--act", "--automation", "--protect", "--help"]

    static func run(mode: String, arguments: [String]) async -> Int32 {
        switch mode {
        case "--agent":
            let force = arguments.contains("--now") ? CleanupRun.Trigger.manual : nil
            _ = await BackgroundAgent.runOnce(force: force, dryRun: arguments.contains("--dry-run"))
            return 0
        case "--protect":
            var settings = AutomationSettings.load()
            for path in arguments {
                let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: cwd).standardized.resolvingSymlinksInPath()
                guard FileManager.default.fileExists(atPath: url.path) else {
                    print("No such folder: \(url.path)")
                    return 1
                }
                let tilde = url.path.hasPrefix(NSHomeDirectory()) ? "~" + url.path.dropFirst(NSHomeDirectory().count) : url.path
                if !settings.protectedFolders.contains(tilde) { settings.protectedFolders.append(tilde) }
            }
            settings.save()
            print("Protected folders: \(settings.protectedFolders.joined(separator: ", "))")
            return 0
        case "--automation":
            var settings = AutomationSettings.load()
            if let state = arguments.first, state == "on" || state == "off" {
                settings.lowDiskEnabled = state == "on"
                settings.scheduleEnabled = state == "on" && settings.scheduleEnabled
                settings.save()
                do {
                    try await MainActor.run { try AgentRegistration.setEnabled(settings.lowDiskEnabled || settings.scheduleEnabled) }
                } catch {
                    print("Couldn't change the background agent: \(error.localizedDescription)")
                    return 1
                }
            }
            let status = await MainActor.run { AgentRegistration.status }
            print("Automatic clean-up: low disk \(settings.lowDiskEnabled ? "on" : "off"), schedule \(settings.scheduleEnabled ? "on" : "off"). Agent: \(status == .enabled ? "registered" : "not registered") (\(status.rawValue))")
            return 0
        case "--diagnose":
            let diagnosis = VerdictEngine.diagnose(await SystemProbe.capture())
            print(diagnosis.verdict.headline)
            print(diagnosis.verdict.summary)
            for finding in diagnosis.findings {
                print("  [\(finding.severity)] \(finding.title): \(finding.detail)")
            }
            let snapshot = diagnosis.snapshot
            print("CPU \(Format.percent(snapshot.cpu.usage * 100)), memory \(Format.memory(snapshot.memory.used)) of \(Format.memory(snapshot.memory.total)), \(Format.bytes(snapshot.disk.available)) free on disk")
            for process in snapshot.processes.sorted(by: { $0.cpuPercent > $1.cpuPercent }).prefix(6) {
                print("  \(process.pid)\t\(Format.percent(process.cpuPercent))\t\(Format.memory(process.memoryBytes))\t\(process.name)")
            }
            let agents = snapshot.agents
            print("Agent sessions: \(agents.sessions.count)")
            for session in agents.sessions {
                let processes = session.processCount == 1 ? "1 process" : "\(session.processCount) processes"
                print("  \(session.pid)\t\(session.kind.rawValue)\t\(Format.percent(session.cpuPercent))\t\(Format.memory(session.memoryBytes))\t\(processes)\t\(session.place?.title ?? "?")")
            }
            print("Simulators: \(agents.simulators.count)")
            for simulator in agents.simulators {
                print("  \(simulator.name) (\(simulator.runtime))\t\(Format.percent(simulator.cpuPercent))\t\(Format.memory(simulator.memoryBytes))\t\(simulator.idleReason ?? "in use by \(simulator.users.map(\.name).joined(separator: ", "))")")
            }
            print("Tools: \(agents.tools.count)")
            for tool in agents.tools {
                print("  \(tool.pid)\t\(tool.label)\t\(tool.owner)\t\(tool.place?.title ?? "?")\t\(tool.ports)\t\(tool.isStoppable ? "STOPPABLE" : "")")
            }
            return 0
        case "--scan":
            let settings = AutomationSettings.load()
            let categories = arguments.compactMap(CleanupCategory.init(rawValue:))
            let context = await ScanContext.capture(activityWindow: settings.activityWindow, projectRoots: settings.projectRoots)
            print("Project roots: \(settings.projectRoots.map(\.path).joined(separator: ", "))")
            print("lsof complete: \(context.inUse.isComplete), simulators read: \(context.simulators.devicesKnown)")
            let inRoots = context.external.references.filter { ref in settings.projectRoots.contains { ref.path.hasPrefix($0.path + "/") } }
            print("External references into project folders: \(inRoots.count) of \(context.external.references.count)")
            for ref in inRoots.prefix(10) { print("  \(ref.path)  (\(ref.source))") }
            for category in categories.isEmpty ? CleanupCategory.allCases : categories {
                let items = await CleanupScanner.discover(category, in: context)
                let total = items.filter(\.isCleanable).reduce(Int64(0)) { $0 + $1.bytes }
                print("\n== \(category.rawValue): \(Format.bytes(total)) can be cleaned up")
                for item in items {
                    let status = item.blocked.map { "BLOCKED: \($0.description)" } ?? "ok"
                    print("  \(Format.bytes(item.bytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(item.title)  [\(status)]")
                }
            }
            return 0
        case "--act" where arguments.first == "stop-tool" || arguments.first == "shutdown-simulator":
            guard arguments.count == 2 else { return 64 }
            let agents = await SystemProbe.capture(sampleInterval: .milliseconds(300)).agents
            let problem: String?
            if arguments[0] == "stop-tool", let pid = pid_t(arguments[1]), let tool = agents.tools.first(where: { $0.pid == pid }) {
                problem = await AgentActions.stop(tool)
            } else if let simulator = agents.simulators.first(where: { $0.udid == arguments[1] }) {
                problem = await AgentActions.shutDown(simulator)
            } else {
                problem = "Couldn't find \(arguments[1])"
            }
            print(problem ?? "Done: \(arguments[0]) \(arguments[1])")
            return problem == nil ? 0 : 1
        case "--act":
            let actions: [String: ProcessAction] = ["quit": .quit, "forceQuit": .forceQuit, "pause": .pause, "resume": .resume]
            guard arguments.count == 2, let action = actions[arguments[0]], let pid = pid_t(arguments[1]),
                  let process = await SystemProbe.capture(sampleInterval: .milliseconds(100)).processes.first(where: { $0.pid == pid })
            else {
                print("Usage: --act quit|forceQuit|pause|resume <pid>")
                return 64
            }
            do {
                try await MainActor.run { try ProcessController.perform(action, on: process) }
                print("Sent \(arguments[0]) to \(process.name) (\(pid))")
                return 0
            } catch {
                print(error)
                return 1
            }
        default:
            print("""
            Run MacUnclog without arguments to open the app.
              --diagnose            print the verdict and findings
              --scan [category …]   show what can be cleaned up, without deleting anything
              --agent [--dry-run]   run the background agent once (--now forces a clean-up)
              --act ACTION PID      quit, forceQuit, pause or resume, with the same rules as the app
              --act stop-tool PID   stop a tool that no session owns any more
              --act shutdown-simulator UDID   shut down an unused simulator
              --automation [on|off] show or change automatic clean-up and the background agent
              --protect PATH …      never delete anything in these folders (also in Settings)
            Categories: \(CleanupCategory.allCases.map(\.rawValue).joined(separator: " "))
            """)
            return 0
        }
    }
}
