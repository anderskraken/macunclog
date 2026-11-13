import Foundation
import ServiceManagement
import UserNotifications

/// The launchd agent. launchd starts `MacUnclog --agent` every 15 minutes; each run
/// decides whether a cleanup is due, does it, notifies, records it and exits.
enum BackgroundAgent {
    static let plistName = "io.github.anderskraken.macunclog.agent.plist"
    static let lowDiskCooldown: TimeInterval = 6 * 3600
    static let stillLowWarningInterval: TimeInterval = 24 * 3600

    enum Decision: Equatable {
        case nothing
        case clean(CleanupRun.Trigger)
    }

    static func decide(settings: AutomationSettings, state: AgentState, freeBytes: Int64, now: Date, calendar: Calendar = .current) -> Decision {
        if settings.lowDiskEnabled, freeBytes < settings.lowDiskThreshold {
            if state.lastLowDiskRun.map({ now.timeIntervalSince($0) >= lowDiskCooldown }) ?? true {
                return .clean(.lowDisk)
            }
        }
        if settings.scheduleEnabled, now >= nextScheduledRun(settings: settings, last: state.lastScheduledRun, now: now, calendar: calendar) {
            return .clean(.schedule)
        }
        return .nothing
    }

    /// The first chosen hour once a full interval (less an hour of slack) has passed since
    /// the last run. A Mac that sleeps through it runs as soon as it wakes.
    static func nextScheduledRun(settings: AutomationSettings, last: Date?, now: Date, calendar: Calendar = .current) -> Date {
        let earliest = last.map { $0.addingTimeInterval(settings.frequency.interval - 3600) } ?? calendar.startOfDay(for: now)
        let components = DateComponents(hour: settings.hour, minute: 0, second: 0)
        return calendar.nextDate(after: earliest.addingTimeInterval(-1), matching: components, matchingPolicy: .nextTime) ?? earliest
    }

    static func runOnce(force: CleanupRun.Trigger? = nil, dryRun: Bool = false) async -> CleanupRun? {
        let settings = AutomationSettings.load()
        var state = AgentState.load()
        let now = Date.now
        let free = SystemProbe.disk().available
        state.lastCheck = now
        defer { if !dryRun { state.save() } }

        let decision = force.map(Decision.clean) ?? decide(settings: settings, state: state, freeBytes: free, now: now)
        guard case .clean(let trigger) = decision else {
            log("Nothing to do. Free space: \(Format.bytes(free)).")
            return nil
        }
        guard CleanupLock.isFree else {
            log("Another clean-up is running; trying again next time.")
            return nil
        }
        log("Starting clean-up (\(trigger.rawValue)). Free space: \(Format.bytes(free)).")
        // Record the attempt before doing anything, so a crash half-way doesn't make the
        // next 15-minute tick start over and over.
        let previous = state
        if !dryRun {
            switch trigger {
            case .lowDisk: state.lastLowDiskRun = now
            case .schedule: state.lastScheduledRun = now
            case .manual: break
            }
            state.save()
        }

        let context = await ScanContext.capture(activityWindow: settings.activityWindow, projectRoots: settings.projectRoots)
        var items: [CleanupItem] = []
        for category in CleanupCategory.allCases where settings.includedCategories.contains(category) {
            items += await CleanupScanner.discover(category, in: context).filter(\.isCleanable)
        }
        if dryRun {
            for item in items { log("[dry run] \(item.category.rawValue): \(item.title) \(Format.bytes(item.bytes))") }
            return nil
        }

        guard let run = await CleanupExecutor.run(items, trigger: trigger, activityWindow: settings.activityWindow,
                                                  projectRoots: settings.projectRoots)
        else {
            log("Another clean-up started first; nothing was done.")
            // Give the slot back, so the schedule or the low-disk check runs next time.
            state.lastLowDiskRun = previous.lastLowDiskRun
            state.lastScheduledRun = previous.lastScheduledRun
            return nil
        }
        HistoryStore.save(run)
        log("Done: \(run.removedCount) \(run.removedCount == 1 ? "item" : "items"), \(Format.bytes(run.reclaimed)). Free space now: \(Format.bytes(run.freeAfter)).")

        if settings.notify {
            // An empty low-disk run is covered by the once-a-day "still low" warning below.
            if run.removedCount > 0 || trigger != .lowDisk {
                await Notifier.post(run: run, settings: settings)
            }
            if trigger == .lowDisk, run.freeAfter < settings.lowDiskThreshold,
               state.lastStillLowWarning.map({ now.timeIntervalSince($0) >= stillLowWarningInterval }) ?? true {
                state.lastStillLowWarning = now
                await Notifier.postStillLow(free: run.freeAfter, settings: settings)
            }
        }
        return run
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[MacUnclog agent] \(message)\n".utf8))
    }
}

/// Registers the launchd agent through SMAppService, so it shows up under Login Items
/// in System Settings with the app's name and icon.
@MainActor
enum AgentRegistration {
    static var service: SMAppService { SMAppService.agent(plistName: BackgroundAgent.plistName) }

    static var status: SMAppService.Status { service.status }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if service.status != .enabled { try service.register() }
        } else if service.status != .notRegistered && service.status != .notFound {
            try service.unregister()
        }
    }

    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }
}

enum Notifier {
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func post(run: CleanupRun, settings: AutomationSettings) async {
        let content = UNMutableNotificationContent()
        let why = switch (run.trigger, settings.frequency) {
        case (.lowDisk, _): String(localized: "Free space fell below \(settings.lowDiskThresholdGB) GB.")
        case (.schedule, .daily): String(localized: "Scheduled clean-up (daily).")
        case (.schedule, .weekly): String(localized: "Scheduled clean-up (weekly).")
        case (.manual, _): String(localized: "Manual clean-up.")
        }
        if run.removedCount == 0 {
            content.title = String(localized: "MacUnclog found nothing safe to delete")
            content.body = String(localized: "\(why) Everything it could clean up was in use or recently changed.")
        } else {
            content.title = String(localized: "MacUnclog freed up \(Format.bytes(run.reclaimed))")
            let categories = Set(run.outcomes.filter { $0.result == .removed }.map(\.category))
            let names = ListFormatter.localizedString(byJoining: CleanupCategory.allCases.filter(categories.contains).map(inSentence))
            content.body = String(localized: "\(why) Cleaned up \(names). \(Format.bytes(run.freeAfter)) is now free.")
        }
        content.sound = nil
        await deliver(content, id: run.id.uuidString)
    }

    static func postStillLow(free: Int64, settings: AutomationSettings) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Still low on space")
        content.body = String(localized: "Only \(Format.bytes(free)) is free after the clean-up. Open MacUnclog to see what is taking up space.")
        await deliver(content, id: "still-low")
    }

    /// A category title as it reads mid-sentence. Xcode and Docker keep their capital.
    private static func inSentence(_ category: CleanupCategory) -> String {
        let title = category.title
        guard category != .xcode, category != .docker, let first = title.first else { return title }
        return first.lowercased() + title.dropFirst()
    }

    private static func deliver(_ content: UNMutableNotificationContent, id: String) async {
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
