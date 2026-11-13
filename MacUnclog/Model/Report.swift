import Foundation

/// What `--diagnose --json`, `--scan --json` and `--files --json` print. Kinds, severities,
/// reasons and actions are fixed identifiers that scripts and agents can match on; titles
/// and descriptions are for people and follow the Mac's language.
enum Report {
    static let schema = 1

    static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Diagnosis

    struct DiagnosisReport: Encodable {
        var schema = Report.schema
        let takenAt: Date
        /// Seconds between the first and last measurement. A CPU load only counts as lasting after 15.
        let measuredSeconds: Int
        let verdict: VerdictReport
        let findings: [FindingReport]
        let system: SystemReport
        let topProcesses: [ProcessReport]
        let agents: AgentsReport

        init(_ diagnosis: Diagnosis, measuredSeconds: Int) {
            let snapshot = diagnosis.snapshot
            takenAt = snapshot.takenAt
            self.measuredSeconds = measuredSeconds
            verdict = VerdictReport(severity: diagnosis.verdict.severity.id, headline: diagnosis.verdict.headline,
                                    summary: diagnosis.verdict.summary)
            findings = diagnosis.findings.map(FindingReport.init)
            system = SystemReport(snapshot)
            topProcesses = snapshot.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(10).map(ProcessReport.init)
            agents = AgentsReport(snapshot.agents)
        }
    }

    struct VerdictReport: Encodable {
        let severity: String
        let headline: String
        let summary: String
    }

    struct FindingReport: Encodable {
        let kind: String
        let pid: pid_t?
        let severity: String
        let title: String
        let detail: String
        let sustainedSeconds: Int?
        let remedies: [RemedyReport]

        init(_ finding: Finding) {
            (kind, pid) = finding.kind.report
            severity = finding.severity.id
            title = finding.title
            detail = finding.detail
            sustainedSeconds = finding.sustainedSeconds.map { Int($0.rounded()) }
            remedies = finding.remedies.map(RemedyReport.init)
        }
    }

    struct RemedyReport: Encodable {
        let action: String
        let pid: pid_t?
        let name: String?
        let count: Int?
        /// The arguments that do the same from the command line, when there is one.
        let command: String?

        init(_ remedy: Remedy) {
            switch remedy {
            case .quit(let ref): (action, pid, name, count, command) = ("quit", ref.pid, ref.name, nil, "--act quit \(ref.pid)")
            case .forceQuit(let ref): (action, pid, name, count, command) = ("forceQuit", ref.pid, ref.name, nil, "--act forceQuit \(ref.pid)")
            case .resume(let ref): (action, pid, name, count, command) = ("resume", ref.pid, ref.name, nil, "--act resume \(ref.pid)")
            case .freeDisk: (action, pid, name, count, command) = ("freeDisk", nil, nil, nil, "--scan")
            case .openBatterySettings: (action, pid, name, count, command) = ("openBatterySettings", nil, nil, nil, nil)
            case .shutDownIdleSimulators(let n): (action, pid, name, count, command) = ("shutDownIdleSimulators", nil, nil, n, nil)
            case .stopOrphanedTools(let n): (action, pid, name, count, command) = ("stopOrphanedTools", nil, nil, n, nil)
            case .showAgents: (action, pid, name, count, command) = ("showAgents", nil, nil, nil, nil)
            }
        }
    }

    struct SystemReport: Encodable {
        let cpuUsage: Double
        let load1: Double
        let cores: Int
        let memoryTotalBytes: UInt64
        let memoryUsedBytes: UInt64
        let memoryPressure: String
        let swapUsedBytes: UInt64
        let diskTotalBytes: Int64
        let diskAvailableBytes: Int64
        let thermal: String
        let lowPowerMode: Bool
        let onBattery: Bool
        let uptimeSeconds: Int

        init(_ snapshot: SystemSnapshot) {
            cpuUsage = (snapshot.cpu.usage * 100).rounded() / 100
            load1 = (snapshot.cpu.load1 * 100).rounded() / 100
            cores = snapshot.cpu.cores
            memoryTotalBytes = snapshot.memory.total
            memoryUsedBytes = snapshot.memory.used
            memoryPressure = switch snapshot.memory.pressure {
            case .normal: "normal"
            case .warning: "warning"
            case .critical: "critical"
            }
            swapUsedBytes = snapshot.memory.swapUsed
            diskTotalBytes = snapshot.disk.total
            diskAvailableBytes = snapshot.disk.available
            thermal = switch snapshot.thermal {
            case .nominal: "nominal"
            case .fair: "fair"
            case .serious: "serious"
            case .critical: "critical"
            }
            lowPowerMode = snapshot.power.lowPowerMode
            onBattery = snapshot.power.onBattery
            uptimeSeconds = Int(snapshot.uptime)
        }
    }

    struct ProcessReport: Encodable {
        let pid: pid_t
        let name: String
        let cpuPercent: Double
        let memoryBytes: UInt64
        let path: String?

        init(_ process: ProcessSample) {
            pid = process.pid
            name = process.name
            cpuPercent = process.cpuPercent.rounded()
            memoryBytes = process.memoryBytes
            path = process.executablePath
        }
    }

    struct AgentsReport: Encodable {
        struct Session: Encodable {
            let pid: pid_t
            let agent: String
            let folder: String?
            let processCount: Int
            let cpuPercent: Double
            let memoryBytes: UInt64
        }

        struct Simulator: Encodable {
            let udid: String
            let name: String
            let runtime: String
            let cpuPercent: Double
            let memoryBytes: UInt64
            let usedBy: [String]
            let idle: Bool
            let idleReason: String?
            let command: String?
        }

        struct Tool: Encodable {
            let pid: pid_t
            let kind: String
            let label: String
            let folder: String?
            let ports: [Int]
            /// "session", "terminal", "orphaned" (its agent session has ended) or "unknown".
            let owner: String
            let ownerPID: pid_t?
            let stoppable: Bool
            let command: String?
        }

        let sessions: [Session]
        let simulators: [Simulator]
        let tools: [Tool]

        init(_ load: AgentLoad) {
            sessions = load.sessions.map {
                Session(pid: $0.pid, agent: $0.kind.rawValue.lowercased(), folder: $0.folder, processCount: $0.processCount,
                        cpuPercent: $0.cpuPercent.rounded(), memoryBytes: $0.memoryBytes)
            }
            simulators = load.simulators.map {
                Simulator(udid: $0.udid, name: $0.name, runtime: $0.runtime, cpuPercent: $0.cpuPercent.rounded(),
                          memoryBytes: $0.memoryBytes, usedBy: $0.users.map(\.name), idle: $0.idleReason != nil,
                          idleReason: $0.idleReason, command: $0.idleReason == nil ? nil : "--act shutdown-simulator \($0.udid)")
            }
            tools = load.tools.map { tool in
                let (owner, ownerPID): (String, pid_t?) = switch tool.owner {
                case .session(let pid, _): ("session", pid)
                case .terminal: ("terminal", nil)
                case .orphaned: ("orphaned", nil)
                case .unknown: ("unknown", nil)
                }
                return Tool(pid: tool.pid, kind: tool.kind.rawValue, label: tool.label, folder: tool.folder, ports: tool.ports,
                            owner: owner, ownerPID: ownerPID, stoppable: tool.isStoppable,
                            command: tool.isStoppable ? "--act stop-tool \(tool.pid)" : nil)
            }
        }
    }

    // MARK: Scan

    struct ScanReport: Encodable {
        var schema = Report.schema
        let categories: [CategoryReport]
    }

    struct CategoryReport: Encodable {
        let id: String
        let title: String
        let cleanableBytes: Int64
        let items: [ItemReport]

        init(_ category: CleanupCategory, items: [CleanupItem]) {
            id = category.rawValue
            title = category.title
            cleanableBytes = items.filter(\.isCleanable).reduce(0) { $0 + $1.bytes }
            self.items = items.map(ItemReport.init)
        }
    }

    struct ItemReport: Encodable {
        let id: String
        let title: String
        let location: String?
        let bytes: Int64
        let lastUsed: Date?
        let blocked: BlockReport?

        init(_ item: CleanupItem) {
            id = item.id
            title = item.title
            location = item.location
            bytes = item.bytes
            lastUsed = item.lastUsed
            blocked = item.blocked.map(BlockReport.init)
        }
    }

    struct BlockReport: Encodable {
        let reason: String
        let description: String

        init(_ reason: BlockReason) {
            self.reason = reason.id
            description = reason.description
        }
    }

    // MARK: Files

    struct FilesReport: Encodable {
        struct File: Encodable {
            let path: String
            let kind: String
            let bytes: Int64
            let modified: Date?
            let blocked: BlockReport?
        }

        var schema = Report.schema
        let files: [File]

        init(_ files: [PersonalFile]) {
            self.files = files.map {
                File(path: $0.path, kind: $0.kind.rawValue, bytes: $0.bytes, modified: $0.modified, blocked: $0.blocked.map(BlockReport.init))
            }
        }
    }
}

extension Severity {
    var id: String {
        switch self {
        case .good: "good"
        case .notice: "notice"
        case .warning: "warning"
        case .critical: "critical"
        }
    }
}

extension Finding.Kind {
    var report: (kind: String, pid: pid_t?) {
        switch self {
        case .memoryPressure: ("memoryPressure", nil)
        case .swap: ("swap", nil)
        case .notResponding(let pid): ("notResponding", pid)
        case .cpuSaturated: ("cpuSaturated", nil)
        case .cpuHog(let pid): ("cpuHog", pid)
        case .memoryHog(let pid): ("memoryHog", pid)
        case .lowDisk: ("lowDisk", nil)
        case .thermal: ("thermal", nil)
        case .lowPowerMode: ("lowPowerMode", nil)
        case .stopped(let pid): ("stopped", pid)
        case .longUptime: ("longUptime", nil)
        case .simulators: ("simulators", nil)
        case .orphanedTools: ("orphanedTools", nil)
        case .agentLoad: ("agentLoad", nil)
        }
    }
}

extension BlockReason {
    var id: String {
        switch self {
        case .recentlyModified: "recentlyModified"
        case .workingDirectory: "workingDirectory"
        case .openFile: "openFile"
        case .notGitIgnored: "notGitIgnored"
        case .notInGitRepository: "notInGitRepository"
        case .runtimeInUse: "runtimeInUse"
        case .simulatorRunning: "simulatorRunning"
        case .protectedPath: "protectedPath"
        case .inUseUnknown: "inUseUnknown"
        case .linkedFrom: "linkedFrom"
        case .usedFromOutside: "usedFromOutside"
        case .configUnreadable: "configUnreadable"
        case .activityUnknown: "activityUnknown"
        }
    }
}
