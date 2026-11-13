import Foundation

struct DiagnosisThresholds: Sendable {
    var lowDiskBytes: Int64 = 20 * Format.gigabyte
    var criticalDiskBytes: Int64 = 10 * Format.gigabyte
    var cpuHogPercent: Double = 80
    var memoryHogBytes: UInt64 = 2 * UInt64(Format.gigabyte)
    var longUptime: TimeInterval = 14 * 86_400
}

/// Turns a snapshot into ranked findings and one verdict. Each rule reads the snapshot
/// and returns zero or more findings; the verdict is built from the worst of them.
enum VerdictEngine {
    typealias Rule = @Sendable (SystemSnapshot, DiagnosisThresholds) -> [Finding]

    static let rules: [Rule] = [
        notResponding, simulators, orphanedTools, agentLoad, memory, cpu, memoryHogs, disk, thermal, lowPowerMode, stopped, uptime,
    ]

    static func diagnose(_ snapshot: SystemSnapshot, thresholds: DiagnosisThresholds = .init()) -> Diagnosis {
        let findings = rules
            .flatMap { $0(snapshot, thresholds) }
            .sorted { $0.severity > $1.severity }
        return Diagnosis(snapshot: snapshot, findings: findings, verdict: verdict(for: findings))
    }

    static func verdict(for findings: [Finding]) -> Verdict {
        let serious = findings.filter { $0.severity >= .warning }
        guard let first = serious.first else {
            if findings.isEmpty {
                return Verdict(severity: .good, headline: String(localized: "Your Mac is fine"),
                               summary: String(localized: "Memory, CPU, disk and temperature look normal. Nothing here is slowing your Mac down right now."))
            }
            if findings.allSatisfy(\.isCPUSpike) {
                return Verdict(severity: .notice, headline: String(localized: "Your Mac is mostly fine"),
                               summary: String(localized: "The CPU is busy right now. If it stays busy, MacUnclog will say what’s slowing your Mac down."))
            }
            return Verdict(severity: .notice, headline: String(localized: "Your Mac is mostly fine"),
                           summary: findings.count == 1
                               ? String(localized: "Nothing is slowing your Mac down right now. One thing is worth a look.")
                               : String(localized: "Nothing is slowing your Mac down right now. \(findings.count) things are worth a look."))
        }
        let headline = serious.count > 1
            ? String(localized: "Your Mac is slow because \(first.reason) and \(serious[1].reason)",
                     comment: "Both arguments are Finding.reason clauses.")
            : String(localized: "Your Mac is slow because \(first.reason)", comment: "The argument is a Finding.reason clause.")
        return Verdict(severity: first.severity, headline: headline, summary: first.detail)
    }

    // MARK: Rules

    private static func quitRemedies(_ process: ProcessSample) -> [Remedy] {
        let actions = ProcessPolicy.allowedActions(for: process)
        let ref = ProcessRef(pid: process.pid, name: process.name)
        var remedies: [Remedy] = []
        if actions.contains(.quit) { remedies.append(.quit(ref)) }
        if actions.contains(.forceQuit) { remedies.append(.forceQuit(ref)) }
        return remedies
    }

    private static func explanation(_ process: ProcessSample) -> String {
        ProcessKnowledge.entry(for: process.name).map { " \($0.explanation)" } ?? ""
    }

    static let notResponding: Rule = { snapshot, _ in
        snapshot.processes.filter(\.isNotResponding).map { process in
            Finding(
                kind: .notResponding(process.pid),
                severity: .critical,
                title: String(localized: "\(process.name) is not responding"),
                reason: String(localized: "\(process.name) has stopped responding"),
                detail: String(localized: "\(process.name) has stopped responding. Force quitting closes the app without saving."),
                symbol: "hourglass",
                remedies: quitRemedies(process).filter { if case .forceQuit = $0 { true } else { false } }
            )
        }
    }

    static let simulators: Rule = { snapshot, _ in
        let agents = snapshot.agents
        let count = agents.simulators.count
        guard count >= 2 else { return [] }
        let idle = agents.idleSimulators.count
        let underPressure = snapshot.memory.pressure != .normal
        let severity: Severity = count >= 4 || (underPressure && count >= 2) ? .warning : .notice
        let idleText = switch idle {
        case 0: String(localized: "All of them seem to be in use.")
        case 1: String(localized: "One of them is idle.")
        default: String(localized: "\(idle) of them are idle.")
        }
        let amount = Format.memory(agents.simulatorMemory)
        let usage = snapshot.memory.swapUsed > 4 << 30
            ? String(localized: "They are using \(amount) of memory, much of it in swap.")
            : String(localized: "They are using \(amount) of memory.")
        return [Finding(
            kind: .simulators, severity: severity, title: String(localized: "\(count) simulators are running at once"),
            reason: String(localized: "\(count) simulators are running at once"),
            detail: String(localized: "\(usage) \(idleText)"),
            symbol: "iphone.gen3.radiowaves.left.and.right",
            remedies: idle > 0 ? [.shutDownIdleSimulators(idle), .showAgents] : [.showAgents])]
    }

    static let orphanedTools: Rule = { snapshot, _ in
        let tools = snapshot.agents.stoppableTools
        guard !tools.isEmpty else { return [] }
        let cpu = tools.reduce(0) { $0 + $1.cpuPercent }
        let memory = tools.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        let names = ListFormatter.localizedString(byJoining: Array(Set(tools.map(\.label))).sorted())
        let heavy = cpu >= 50 || memory >= 2 << 30
        let one = tools.count == 1
        return [Finding(
            kind: .orphanedTools, severity: heavy ? .warning : .notice,
            title: one ? String(localized: "1 tool was left running")
                : String(localized: "\(tools.count) tools were left running"),
            reason: one ? String(localized: "a tool was left running")
                : String(localized: "\(tools.count) tools were left running"),
            detail: one
                ? String(localized: "The session that started \(names) has ended. It uses \(Format.memory(memory)) of memory and \(Format.percent(cpu)) CPU.")
                : String(localized: "The sessions that started \(names) have ended. They use \(Format.memory(memory)) of memory and \(Format.percent(cpu)) CPU."),
            symbol: "powerplug", remedies: [.stopOrphanedTools(tools.count), .showAgents])]
    }

    static let agentLoad: Rule = { snapshot, _ in
        let sessions = snapshot.agents.sessions
        let cpu = sessions.reduce(0) { $0 + $1.cpuPercent }
        let capacity = Double(max(snapshot.cpu.cores, 1)) * 100
        guard sessions.count >= 2, cpu >= 150 || cpu >= capacity * 0.3 else { return [] }
        let share = Format.percent(min(100, cpu / capacity * 100))
        let memory = Format.memory(sessions.reduce(0) { $0 + $1.memoryBytes })
        return [Finding(
            kind: .agentLoad, severity: cpu >= capacity * 0.5 ? .warning : .notice,
            title: String(localized: "\(sessions.count) agent sessions are using \(share) of the CPU"),
            reason: String(localized: "\(sessions.count) agent sessions and their tools are keeping \(Format.cores(cpu)) busy"),
            detail: String(localized: "The Claude and Codex sessions, with everything they started (builds, tests, servers), are using \(Format.cores(cpu)) and \(memory) of memory."),
            symbol: "person.2.wave.2", remedies: [.showAgents])]
    }

    static let memory: Rule = { snapshot, thresholds in
        let memory = snapshot.memory
        let swap = Format.memory(memory.swapUsed)
        let remedies = AppUsage.quittable(snapshot.processes).prefix(2).flatMap { quitRemedies($0.app).prefix(1) }

        switch memory.pressure {
        case .critical:
            return [Finding(kind: .memoryPressure, severity: .critical, title: String(localized: "Memory is full"),
                            reason: String(localized: "memory is full"),
                            detail: String(localized: "Memory pressure is critical and \(swap) is in swap. Apps have to wait for the disk every time they need memory."),
                            symbol: "memorychip.fill", remedies: Array(remedies))]
        case .warning:
            return [Finding(kind: .memoryPressure, severity: .warning, title: String(localized: "Memory is almost full"),
                            reason: String(localized: "memory is almost full"),
                            detail: String(localized: "Memory pressure is high and \(swap) is in swap. Quit apps you aren’t using."),
                            symbol: "memorychip", remedies: Array(remedies))]
        case .normal:
            if memory.isSwappingActively && memory.swapUsed > UInt64(Format.gigabyte) {
                return [Finding(kind: .swap, severity: .warning, title: String(localized: "Your Mac is moving memory to disk"),
                                reason: String(localized: "there isn’t enough memory"),
                                detail: String(localized: "\(swap) is in swap and macOS is swapping right now. This makes switching between apps slow."),
                                symbol: "arrow.left.arrow.right", remedies: Array(remedies))]
            }
            if memory.swapUsed > 8 * UInt64(Format.gigabyte) {
                return [Finding(kind: .swap, severity: .notice, title: String(localized: "\(swap) is in swap"),
                                reason: String(localized: "a lot of memory is in swap"),
                                detail: String(localized: "Memory pressure is normal now, but swap still holds data from an earlier peak. A restart clears it."),
                                symbol: "arrow.left.arrow.right")]
            }
            return []
        }
    }

    /// A process or a full CPU only counts against the Mac once the load has lasted (see
    /// `CPUStreaks`). A spike is a notice that says "right now" and stays out of the headline.
    static let cpu: Rule = { snapshot, thresholds in
        let ownPID = getpid()
        let streaks = snapshot.cpuStreaks
        let hogs = snapshot.processes
            .filter { $0.cpuPercent >= thresholds.cpuHogPercent && $0.pid != ownPID }
            .sorted { $0.cpuPercent > $1.cpuPercent }
        let saturated = snapshot.cpu.usage >= CPUStreaks.saturatedUsage

        var findings = hogs.prefix(3).map { process in
            let percent = Format.percent(process.cpuPercent)
            let cores = Format.cores(process.cpuPercent)
            guard let lasted = streaks.sustained(process) else {
                return Finding(
                    kind: .cpuHog(process.pid), severity: .notice,
                    title: String(localized: "\(process.name) is using \(percent) CPU right now"),
                    reason: String(localized: "\(process.name) is keeping \(cores) busy"),
                    detail: String(localized: "\(process.name) is keeping \(cores) busy right now.\(explanation(process))"),
                    symbol: "cpu", remedies: quitRemedies(process), sustainedSeconds: nil
                )
            }
            let duration = Format.duration(lasted)
            let severity: Severity = streaks.saturatedFor != nil || process.cpuPercent >= 150 ? .warning : .notice
            return Finding(
                kind: .cpuHog(process.pid), severity: severity,
                title: String(localized: "\(process.name) has used \(percent) CPU for \(duration)"),
                reason: String(localized: "\(process.name) has kept \(cores) busy for \(duration)"),
                detail: String(localized: "\(process.name) has kept \(cores) busy for \(duration).\(explanation(process))"),
                symbol: "cpu", remedies: quitRemedies(process), sustainedSeconds: lasted
            )
        }
        // A long build saturates the CPU with compilers that each live a few seconds, so no
        // single process lasts. A full CPU that lasts counts even then.
        let lastingHog = findings.contains { $0.severity >= .warning }
        if saturated && !lastingHog {
            let usage = Format.percent(snapshot.cpu.usage * 100)
            if let lasted = streaks.saturatedFor {
                let duration = Format.duration(lasted)
                findings.append(Finding(
                    kind: .cpuSaturated, severity: .warning,
                    title: String(localized: "The CPU has been fully loaded for \(duration)"),
                    reason: String(localized: "the CPU has been fully loaded for \(duration)"),
                    detail: String(localized: "\(usage) of the CPU is in use, spread across many processes."),
                    symbol: "cpu.fill", sustainedSeconds: lasted))
            } else if hogs.isEmpty {
                findings.append(Finding(
                    kind: .cpuSaturated, severity: .notice, title: String(localized: "The CPU is fully loaded right now"),
                    reason: String(localized: "the CPU is fully loaded"),
                    detail: String(localized: "\(usage) of the CPU is in use right now, spread across many processes."),
                    symbol: "cpu.fill"))
            }
        }
        return findings
    }

    /// Whole apps, helpers included, like Activity Monitor's grouping. A helper process on
    /// its own is never the thing to quit.
    static let memoryHogs: Rule = { snapshot, thresholds in
        let total = snapshot.memory.total
        let underPressure = snapshot.memory.pressure != .normal
        return AppUsage.quittable(snapshot.processes)
            .filter { $0.memory >= thresholds.memoryHogBytes }
            .filter { underPressure || Double($0.memory) >= Double(total) * 0.3 }
            .prefix(3)
            .map { usage in
                let name = usage.app.name
                let amount = Format.memory(usage.memory)
                let helperCount = usage.processCount - 1
                let share = Format.percent(Double(usage.memory) / Double(max(total, 1)) * 100)
                let detail = switch helperCount {
                case ..<1: String(localized: "\(name) is using \(share) of memory.")
                case 1: String(localized: "\(name), with 1 helper process, is using \(share) of memory.")
                default: String(localized: "\(name), with \(helperCount) helper processes, is using \(share) of memory.")
                }
                return Finding(
                    kind: .memoryHog(usage.app.pid), severity: underPressure ? .warning : .notice,
                    title: String(localized: "\(name) is using \(amount) of memory"),
                    reason: String(localized: "\(name) is using \(amount) of memory"),
                    detail: detail,
                    symbol: "memorychip", remedies: quitRemedies(usage.app)
                )
            }
    }

    static let disk: Rule = { snapshot, thresholds in
        let available = snapshot.disk.available
        let free = Format.bytes(available)
        let detail = String(localized: "Only \(free) is free. When the disk is almost full, macOS has no room for swap and caches, and everything slows down.")
        if available < thresholds.criticalDiskBytes {
            return [Finding(kind: .lowDisk, severity: .critical, title: String(localized: "The disk is almost full"),
                            reason: String(localized: "the disk is almost full"), detail: detail,
                            symbol: "internaldrive.fill", remedies: [.freeDisk])]
        }
        if available < thresholds.lowDiskBytes {
            return [Finding(kind: .lowDisk, severity: .warning, title: String(localized: "Disk space is low"),
                            reason: String(localized: "disk space is low"), detail: detail,
                            symbol: "internaldrive", remedies: [.freeDisk])]
        }
        return []
    }

    static let thermal: Rule = { snapshot, _ in
        switch snapshot.thermal {
        case .nominal: return []
        case .fair:
            return [Finding(kind: .thermal, severity: .notice, title: String(localized: "Your Mac is warm"),
                            reason: String(localized: "it is running warm"),
                            detail: String(localized: "Your Mac is warmer than usual. The fans are working harder, but performance isn’t throttled yet."),
                            symbol: "thermometer.medium")]
        case .serious:
            return [Finding(kind: .thermal, severity: .warning, title: String(localized: "Heat is throttling the CPU"),
                            reason: String(localized: "the CPU is being throttled to cool down"),
                            detail: String(localized: "macOS is slowing down the CPU to keep the temperature down. Give your Mac some air and quit heavy processes."),
                            symbol: "thermometer.high")]
        case .critical:
            return [Finding(kind: .thermal, severity: .critical, title: String(localized: "Your Mac is overheating"),
                            reason: String(localized: "it is overheating"),
                            detail: String(localized: "The temperature is critical and performance is heavily throttled. Quit heavy processes and let your Mac cool down."),
                            symbol: "thermometer.sun.fill")]
        }
    }

    static let lowPowerMode: Rule = { snapshot, _ in
        guard snapshot.power.lowPowerMode else { return [] }
        return [Finding(kind: .lowPowerMode, severity: .notice, title: String(localized: "Low Power Mode is on"),
                        reason: String(localized: "Low Power Mode is limiting performance"),
                        detail: String(localized: "Low Power Mode saves battery by slowing down the CPU."),
                        symbol: "battery.25percent", remedies: [.openBatterySettings])]
    }

    static let stopped: Rule = { snapshot, _ in
        snapshot.processes
            .filter { $0.state == .stopped && ProcessPolicy.allowedActions(for: $0).contains(.resume) }
            .prefix(3)
            .map { process in
                Finding(kind: .stopped(process.pid), severity: .notice, title: String(localized: "\(process.name) is paused"),
                        reason: String(localized: "\(process.name) is paused"),
                        detail: String(localized: "\(process.name) is stopped and won’t do anything until it resumes."),
                        symbol: "pause.circle",
                        remedies: [.resume(ProcessRef(pid: process.pid, name: process.name))])
            }
    }

    static let uptime: Rule = { snapshot, thresholds in
        guard snapshot.uptime > thresholds.longUptime else { return [] }
        let days = Int(snapshot.uptime / 86_400)
        return [Finding(kind: .longUptime, severity: .notice, title: String(localized: "Not restarted in \(days) days"),
                        reason: String(localized: "it hasn’t been restarted in a long time"),
                        detail: String(localized: "A restart clears swap and temporary files, and ends processes that have leaked memory."),
                        symbol: "restart")]
    }
}
