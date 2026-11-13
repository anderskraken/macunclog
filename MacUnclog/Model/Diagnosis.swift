import Foundation

enum Severity: Int, Comparable, Sendable, Codable {
    case good, notice, warning, critical

    static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct ProcessRef: Sendable, Hashable {
    let pid: pid_t
    let name: String
}

enum Remedy: Sendable, Hashable {
    case quit(ProcessRef)
    case forceQuit(ProcessRef)
    case resume(ProcessRef)
    case freeDisk
    case openBatterySettings
    case shutDownIdleSimulators(Int)
    case stopOrphanedTools(Int)
    case showAgents
}

struct Finding: Identifiable, Sendable, Hashable {
    enum Kind: Hashable, Sendable {
        case memoryPressure
        case swap
        case notResponding(pid_t)
        case cpuSaturated
        case cpuHog(pid_t)
        case memoryHog(pid_t)
        case lowDisk
        case thermal
        case lowPowerMode
        case stopped(pid_t)
        case longUptime
        case simulators
        case orphanedTools
        case agentLoad
    }

    let kind: Kind
    let severity: Severity
    let title: String
    /// The clause that completes "Your Mac is slow because …".
    let reason: String
    let detail: String
    let symbol: String
    var remedies: [Remedy] = []
    /// For CPU findings: how long the load has lasted, or nil for a spike.
    var sustainedSeconds: TimeInterval?

    var id: Kind { kind }

    /// A busy CPU or process seen in one measurement only.
    var isCPUSpike: Bool {
        switch kind {
        case .cpuHog, .cpuSaturated: sustainedSeconds == nil
        default: false
        }
    }
}

struct Verdict: Sendable, Equatable {
    let severity: Severity
    let headline: String
    let summary: String
}

struct Diagnosis: Sendable {
    let snapshot: SystemSnapshot
    let findings: [Finding]
    let verdict: Verdict
}
