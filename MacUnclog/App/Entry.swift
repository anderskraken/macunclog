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
    static let modes: Set<String> = ["--agent", "--diagnose", "--scan", "--files", "--skill", "--act", "--automation", "--protect", "--benchmark", "--help"]

    static func run(mode: String, arguments: [String]) async -> Int32 {
        switch mode {
        case "--agent":
            let force = arguments.contains("--now") ? CleanupRun.Trigger.manual : nil
            _ = await BackgroundAgent.runOnce(force: force, dryRun: arguments.contains("--dry-run"))
            return 0
        case "--benchmark":
            // Median and spread of N full measurements: wall time, MacUnclog's own CPU time,
            // the CPU time of the tools it starts (ps, lsof), and memory afterwards.
            let runs = arguments.first.flatMap(Int.init) ?? 10
            func cpu(_ who: Int32) -> Double {
                var usage = rusage()
                getrusage(who, &usage)
                return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
            }
            var wall: [Double] = [], own: [Double] = [], children: [Double] = []
            _ = await SystemProbe.capture()
            for _ in 0..<runs {
                let (start, ownStart, childStart) = (ContinuousClock.now, cpu(RUSAGE_SELF), cpu(RUSAGE_CHILDREN))
                _ = VerdictEngine.diagnose(await SystemProbe.capture())
                wall.append((ContinuousClock.now - start).seconds)
                own.append(cpu(RUSAGE_SELF) - ownStart)
                children.append(cpu(RUSAGE_CHILDREN) - childStart)
            }
            func line(_ name: String, _ values: [Double]) {
                let sorted = values.sorted()
                let median = sorted[sorted.count / 2]
                print(name.padding(toLength: 14, withPad: " ", startingAt: 0),
                      String(format: "median %.3f s   min %.3f   max %.3f", median, sorted.first!, sorted.last!))
            }
            print("\(runs) measurements, \(ProcessInfo.processInfo.activeProcessorCount) cores")
            line("wall", wall)
            line("own CPU", own)
            line("child CPU", children)
            var usage = rusage_info_v4()
            _ = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
            }
            print("footprint     \(Format.memory(usage.ri_phys_footprint))")
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
            let json = arguments.contains("--json")
            var seconds = 0
            if let index = arguments.firstIndex(of: "--for") {
                guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), value >= 0 else {
                    print("Usage: --diagnose [--for SECONDS] [--json]")
                    return 64
                }
                seconds = value
            }
            let (diagnosis, measured) = await measure(for: seconds)
            if json {
                print(Report.json(Report.DiagnosisReport(diagnosis, measuredSeconds: measured)))
                return 0
            }
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
        case "--skill":
            let action = arguments.first { ["install", "remove"].contains($0) }
            let named = arguments.compactMap(AgentSkill.Agent.init(rawValue:))
            guard arguments.allSatisfy({ ["install", "remove"].contains($0) || AgentSkill.Agent(rawValue: $0) != nil }),
                  arguments.filter({ ["install", "remove"].contains($0) }).count <= 1
            else {
                print("Usage: --skill [install|remove] [claude|codex]")
                return 64
            }
            let agents = named.isEmpty ? AgentSkill.Agent.allCases.filter { AgentSkill.status(of: $0) != .agentMissing } : named
            do {
                for agent in agents {
                    if action == "install" { try AgentSkill.install(for: agent) }
                    if action == "remove" { try AgentSkill.remove(for: agent) }
                }
            } catch {
                print(error.description)
                return 1
            }
            for agent in AgentSkill.Agent.allCases {
                let status = switch AgentSkill.status(of: agent) {
                case .agentMissing: "not set up on this Mac"
                case .notInstalled: "not installed"
                case .installed: "installed"
                case .different: "a different version is installed"
                }
                print("\(agent.title): \(status) (\(agent.skillFile.path))")
            }
            return 0
        case "--files":
            let files = await PersonalFiles.find(inUse: await InUseSnapshot.capture())
            if arguments.contains("--json") {
                print(Report.json(Report.FilesReport(files)))
                return 0
            }
            for kind in PersonalFile.Kind.allCases {
                let group = files.filter { $0.kind == kind }
                print("== \(kind.rawValue): \(group.count) files, \(Format.bytes(group.reduce(Int64(0)) { $0 + $1.bytes }))")
                for file in group {
                    let status = file.blocked.map { "  [IN USE: \($0.description)]" } ?? ""
                    print("  \(Format.bytes(file.bytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(file.path)\(status)")
                }
            }
            return 0
        case "--scan":
            let settings = AutomationSettings.load()
            let categories = arguments.compactMap(CleanupCategory.init(rawValue:))
            let context = await ScanContext.capture(activityWindow: settings.activityWindow, projectRoots: settings.projectRoots)
            if arguments.contains("--json") {
                var reports: [Report.CategoryReport] = []
                for category in categories.isEmpty ? CleanupCategory.allCases : categories {
                    reports.append(Report.CategoryReport(category, items: await CleanupScanner.discover(category, in: context)))
                }
                print(Report.json(Report.ScanReport(categories: reports)))
                return 0
            }
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
              --diagnose [--for SECONDS] [--json]
                                    print the verdict and findings; with --for, measure for that long
                                    so a lasting CPU load counts (it needs 15 seconds)
              --scan [category …] [--json]
                                    show what can be cleaned up, without deleting anything
              --files [--json]      list installers and large files in your folders, without moving anything
              --skill [install|remove] [claude|codex]
                                    show, install or remove the skill for Claude Code and Codex
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

    /// Measures every five seconds until the first and last measurement are `seconds`
    /// apart, so a CPU load that lasts can be told apart from a spike. Returns the diagnosis
    /// and the seconds actually covered.
    static func measure(for seconds: Int) async -> (Diagnosis, Int) {
        var thresholds = DiagnosisThresholds()
        thresholds.lowDiskBytes = max(AutomationSettings.load().lowDiskThreshold, thresholds.criticalDiskBytes)
        var streaks = CPUStreaks.empty
        var first: Date?
        while true {
            var snapshot = await SystemProbe.capture()
            streaks.record(snapshot, threshold: thresholds.cpuHogPercent)
            let start = first ?? snapshot.takenAt
            first = start
            let covered = snapshot.takenAt.timeIntervalSince(start)
            guard covered < Double(seconds) else {
                snapshot.cpuStreaks = streaks
                return (VerdictEngine.diagnose(snapshot, thresholds: thresholds), Int(covered.rounded()))
            }
            try? await Task.sleep(for: .seconds(min(5, Double(seconds) - covered)))
        }
    }
}
