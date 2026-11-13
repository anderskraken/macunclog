import Foundation

enum MemoryPressure: Int, Sendable, Codable {
    case normal = 1
    case warning = 2
    case critical = 4
}

struct MemorySnapshot: Sendable {
    var total: UInt64
    var appMemory: UInt64
    var wired: UInt64
    var compressed: UInt64
    var cached: UInt64
    var free: UInt64
    var swapUsed: UInt64
    var swapTotal: UInt64
    var pressure: MemoryPressure
    /// Pages swapped in and out per second while the snapshot was sampled.
    var swapPagesPerSecond: Double

    var used: UInt64 { appMemory + wired + compressed }
    var usedFraction: Double { total == 0 ? 0 : min(1, Double(used) / Double(total)) }
    var isSwappingActively: Bool { swapPagesPerSecond > 50 }
}

struct CPUSnapshot: Sendable {
    var usage: Double
    var load1: Double
    var load5: Double
    var cores: Int
}

struct DiskSnapshot: Sendable {
    var total: Int64
    var available: Int64

    var usedFraction: Double { total == 0 ? 0 : 1 - Double(available) / Double(total) }
}

enum ThermalLevel: Int, Sendable, Comparable {
    case nominal, fair, serious, critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct PowerSnapshot: Sendable {
    var onBattery: Bool
    var batteryPercent: Int?
    var lowPowerMode: Bool
}

struct ProcessSample: Identifiable, Sendable, Hashable {
    enum RunState: Sendable, Hashable { case running, stopped, zombie }

    let pid: pid_t
    let name: String
    let executablePath: String?
    let bundleIdentifier: String?
    let isRegularApp: Bool
    let isOwnedByUser: Bool
    let isNotResponding: Bool
    let state: RunState
    /// Percent of one core, like Activity Monitor (can exceed 100).
    let cpuPercent: Double
    let memoryBytes: UInt64
    /// Process start time in seconds since 1970, so an action can tell a reused pid apart.
    var startSeconds: UInt64 = 0

    var id: pid_t { pid }
}

extension MemorySnapshot {
    var severity: Severity {
        switch pressure {
        case .critical: .critical
        case .warning: .warning
        case .normal: isSwappingActively ? .notice : .good
        }
    }
}


extension DiskSnapshot {
    func severity(threshold: Int64) -> Severity {
        available < 10 * Format.gigabyte ? .critical : available < threshold ? .warning : .good
    }
}

struct SystemSnapshot: Sendable {
    var takenAt: Date
    var memory: MemorySnapshot
    var cpu: CPUSnapshot
    var disk: DiskSnapshot
    var thermal: ThermalLevel
    var power: PowerSnapshot
    var processes: [ProcessSample]
    var uptime: TimeInterval
    var agents: AgentLoad = .empty
    /// What earlier measurements saw, so a short spike isn't mistaken for a lasting load.
    var cpuStreaks: CPUStreaks = .empty

    /// The CPU gauge's colour. A full CPU only turns it orange once it has lasted.
    var cpuSeverity: Severity {
        guard cpu.usage >= CPUStreaks.saturatedUsage else { return cpu.usage >= 0.6 ? .notice : .good }
        return cpuStreaks.saturatedFor == nil ? .notice : .warning
    }
}
