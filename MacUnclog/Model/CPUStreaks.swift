import Foundation

/// How long each process, and the CPU as a whole, has stayed busy across measurements.
/// One measurement covers less than a second, and compilers, Spotlight and app launches
/// spike all the time, so a load only counts as a problem once it lasts.
struct CPUStreaks: Sendable {
    struct Streak: Sendable, Equatable {
        var since: Date
        var last: Date
        /// The last measurement at or above the threshold. A dip may last no longer than
        /// `maximumDip`, or two separate spikes would join into one long load.
        var lastAbove: Date

        var duration: TimeInterval { last.timeIntervalSince(since) }
    }

    struct Key: Hashable, Sendable {
        let pid: pid_t
        let startSeconds: UInt64
    }

    /// A load counts as lasting once measurements this far apart, and all in between, saw it.
    static let minimumDuration: TimeInterval = 15
    /// A longer gap between measurements (the Mac slept, the app wasn't running) ends a streak.
    static let maximumGap: TimeInterval = 90
    static let saturatedUsage = 0.85
    /// Once a streak has started it survives a dip to this share of the threshold: another
    /// busy process can take a process's CPU for a moment without the load having ended.
    static let dipAllowed = 0.5
    static let saturationDipAllowed = 0.6
    /// The longest dip a streak survives: one missed measurement at the 10-second refresh.
    static let maximumDip: TimeInterval = 20

    private(set) var processes: [Key: Streak] = [:]
    private(set) var saturation: Streak?

    static let empty = CPUStreaks()

    /// Starts a streak for every process at or above `threshold`, keeps going the ones that
    /// stay above `dipAllowed` of it, and ends every other one.
    mutating func record(_ snapshot: SystemSnapshot, threshold: Double) {
        let now = snapshot.takenAt
        func next(_ streak: Streak?, load: Double, threshold: Double, dip: Double) -> Streak? {
            let above = load >= threshold
            if let streak, load >= threshold * dip, now >= streak.last, now.timeIntervalSince(streak.last) <= Self.maximumGap,
               streak.last == streak.lastAbove && above || now.timeIntervalSince(streak.lastAbove) <= Self.maximumDip {
                return Streak(since: streak.since, last: now, lastAbove: above ? now : streak.lastAbove)
            }
            return above ? Streak(since: now, last: now, lastAbove: now) : nil
        }
        var kept: [Key: Streak] = [:]
        for process in snapshot.processes {
            let key = Key(pid: process.pid, startSeconds: process.startSeconds)
            kept[key] = next(processes[key], load: process.cpuPercent, threshold: threshold, dip: Self.dipAllowed)
        }
        processes = kept
        saturation = next(saturation, load: snapshot.cpu.usage, threshold: Self.saturatedUsage, dip: Self.saturationDipAllowed)
    }

    /// How long `process` has been busy, or nil if it hasn't lasted long enough to count.
    func sustained(_ process: ProcessSample) -> TimeInterval? {
        Self.lasting(processes[Key(pid: process.pid, startSeconds: process.startSeconds)])
    }

    var saturatedFor: TimeInterval? { Self.lasting(saturation) }

    private static func lasting(_ streak: Streak?) -> TimeInterval? {
        guard let streak, streak.duration >= minimumDuration else { return nil }
        return streak.duration
    }
}

/// The streaks the running app keeps, so the Shortcuts action judges CPU load the same way.
@MainActor
enum SharedCPUStreaks {
    static var current = CPUStreaks.empty

    /// Adds `snapshot` to the shared streaks and returns it with them attached.
    static func record(_ snapshot: SystemSnapshot, threshold: Double = DiagnosisThresholds().cpuHogPercent) -> SystemSnapshot {
        current.record(snapshot, threshold: threshold)
        var measured = snapshot
        measured.cpuStreaks = current
        return measured
    }
}
