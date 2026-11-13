import Foundation

enum ScheduleFrequency: String, CaseIterable, Codable, Sendable, Identifiable {
    case daily, weekly

    var id: String { rawValue }
    var title: String { self == .daily ? String(localized: "Daily") : String(localized: "Weekly") }
    var interval: TimeInterval { self == .daily ? 86_400 : 7 * 86_400 }
}

/// Settings shared by the app and the background agent. Both run from the same bundle,
/// so they read the same defaults domain.
struct AutomationSettings: Codable, Sendable, Equatable {
    var lowDiskEnabled = false
    var lowDiskThresholdGB = 20
    var scheduleEnabled = false
    var frequency: ScheduleFrequency = .weekly
    var hour = 3
    var includedCategories: Set<CleanupCategory> = Set(CleanupCategory.allCases.filter(\.includedInAutomaticByDefault))
    var activityWindowDays = 3
    var notify = true
    var extraProjectRoots: [String] = []
    var protectedFolders: [String] = []

    init() {}

    /// Every field is optional on disk, so adding a setting later keeps the user's choices.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AutomationSettings()
        lowDiskEnabled = try container.decodeIfPresent(Bool.self, forKey: .lowDiskEnabled) ?? defaults.lowDiskEnabled
        lowDiskThresholdGB = try container.decodeIfPresent(Int.self, forKey: .lowDiskThresholdGB) ?? defaults.lowDiskThresholdGB
        scheduleEnabled = try container.decodeIfPresent(Bool.self, forKey: .scheduleEnabled) ?? defaults.scheduleEnabled
        frequency = try container.decodeIfPresent(ScheduleFrequency.self, forKey: .frequency) ?? defaults.frequency
        hour = try container.decodeIfPresent(Int.self, forKey: .hour) ?? defaults.hour
        let categories = try container.decodeIfPresent([String].self, forKey: .includedCategories)
        includedCategories = categories.map { Set($0.compactMap(CleanupCategory.init(rawValue:))) } ?? defaults.includedCategories
        activityWindowDays = try container.decodeIfPresent(Int.self, forKey: .activityWindowDays) ?? defaults.activityWindowDays
        notify = try container.decodeIfPresent(Bool.self, forKey: .notify) ?? defaults.notify
        extraProjectRoots = try container.decodeIfPresent([String].self, forKey: .extraProjectRoots) ?? defaults.extraProjectRoots
        protectedFolders = try container.decodeIfPresent([String].self, forKey: .protectedFolders) ?? defaults.protectedFolders
    }

    var lowDiskThreshold: Int64 { Int64(lowDiskThresholdGB) * Format.gigabyte }
    var activityWindow: TimeInterval { TimeInterval(activityWindowDays) * 86_400 }

    var projectRoots: [URL] {
        var roots = CleanupScanner.defaultProjectRoots()
        for path in extraProjectRoots {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if !roots.contains(url) { roots.append(url) }
        }
        return roots
    }

    private static let key = "automationSettings"

    static func load(from defaults: UserDefaults = .standard) -> AutomationSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AutomationSettings.self, from: data)
        else { return AutomationSettings() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// Bookkeeping the agent needs between launches: when it last ran and when it last
/// warned, so a disk that stays full doesn't trigger a cleanup every 15 minutes.
struct AgentState: Codable, Sendable {
    var lastScheduledRun: Date?
    var lastLowDiskRun: Date?
    var lastStillLowWarning: Date?
    var lastCheck: Date?

    private static let key = "agentState"

    static func load(from defaults: UserDefaults = .standard) -> AgentState {
        guard let data = defaults.data(forKey: key), let state = try? JSONDecoder().decode(AgentState.self, from: data)
        else { return AgentState() }
        return state
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}
