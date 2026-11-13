import AppKit
import OSLog
import Observation
import ServiceManagement

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview, agents, processes, disk, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .agents: String(localized: "Agents")
        case .processes: String(localized: "Processes")
        case .disk: String(localized: "Storage")
        case .history: String(localized: "History")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "stethoscope"
        case .agents: "person.2.wave.2"
        case .processes: "cpu"
        case .disk: "internaldrive"
        case .history: "clock.arrow.circlepath"
        }
    }
}

struct CategoryState: Sendable {
    var items: [CleanupItem] = []
    var isScanning = false
    var scanned = false

    var cleanable: [CleanupItem] { items.filter(\.isCleanable) }
}

@MainActor
@Observable
final class AppModel {
    /// `-MUTab disk` on the command line opens a given tab (used by scripts/screenshots.sh).
    var selection: SidebarItem? = UserDefaults.standard.string(forKey: "MUTab").flatMap(SidebarItem.init(rawValue:)) ?? .overview

    private(set) var diagnosis: Diagnosis?
    private(set) var isDiagnosing = false
    private(set) var disk = SystemProbe.disk()

    private(set) var categories: [CleanupCategory: CategoryState] = [:]
    var selectedItems: Set<String> = []
    private(set) var lastScan: Date?
    private(set) var cleaningProgress: CleanupExecutor.Progress?
    private(set) var lastRun: CleanupRun?
    private(set) var history: [CleanupRun] = []

    var message: String?

    var settings = AutomationSettings.load() {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            syncAgent()
        }
    }
    private(set) var agentStatus: SMAppService.Status = .notRegistered

    private var refreshTask: Task<Void, Never>?

    init() {
        #if DEBUG
        if let look = UserDefaults.standard.string(forKey: "MUAppearance") {
            NSApplication.shared.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
        }
        if DemoData.isEnabled {
            history = DemoData.history()
            categories = DemoData.cleanup()
            lastScan = .now
            selectedItems = Set(categories.values.flatMap(\.cleanable).map(\.id))
            return
        }
        #endif
        history = HistoryStore.load()
        syncAgent()
    }

    // MARK: Diagnosis

    private static let log = Logger(subsystem: "io.github.anderskraken.macunclog", category: "refresh")

    /// How many windows or panels are showing live numbers right now.
    private var viewers = 0
    /// Shown windows that other windows cover completely; nobody is looking at those.
    private var coveredWindows = 0

    func setCovered(_ covered: Bool) {
        coveredWindows = max(0, coveredWindows + (covered ? 1 : -1))
        if !covered, let wakeUp {
            self.wakeUp = nil
            wakeUp.resume()
        }
    }
    private var wakeUp: CheckedContinuation<Void, Never>?

    /// Call from onAppear/onDisappear of anything that shows live numbers.
    func setVisible(_ visible: Bool) {
        viewers = max(0, viewers + (visible ? 1 : -1))
        if visible, let wakeUp {
            self.wakeUp = nil
            wakeUp.resume()
        }
    }

    private var fallbackTask: Task<Void, Never>?

    /// launchd won't start the agent from a build that only signs to run locally. When the
    /// agent hasn't checked in for half an hour, the app runs the same check itself.
    func startAgentFallback() {
        guard fallbackTask == nil else { return }
        fallbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15 * 60))
                guard let self, self.automationActive else { continue }
                let lastCheck = AgentState.load().lastCheck ?? .distantPast
                guard Date.now.timeIntervalSince(lastCheck) > 30 * 60 else { continue }
                if await BackgroundAgent.runOnce() != nil { self.reloadHistory() }
            }
        }
    }

    func startAutoRefresh() {
        startAgentFallback()
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled, let self {
                let start = ContinuousClock.now
                await self.refreshDiagnosis()
                // Measuring costs about a CPU second, so it must not add to the load it reports:
                // every 10 s while someone looks, every 30 s for the menu bar icon, and never
                // more often than twice the time a measurement took.
                let took = ContinuousClock.now - start
                let pause = max(self.viewers - self.coveredWindows > 0 ? .seconds(10) : .seconds(30), took * 2)
                Self.log.debug("Measured in \(took.seconds, format: .fixed(precision: 2)) s; next in \(pause.seconds, format: .fixed(precision: 0)) s (viewers \(self.viewers), covered \(self.coveredWindows))")
                await self.sleep(for: pause)
            }
        }
    }

    /// Sleeps, but wakes early when a window or the menu bar panel opens.
    private func sleep(for duration: Duration) async {
        await withCheckedContinuation { continuation in
            wakeUp = continuation
            Task { [weak self] in
                try? await Task.sleep(for: duration)
                guard let self, let pending = self.wakeUp else { return }
                self.wakeUp = nil
                pending.resume()
            }
        }
    }

    func refreshDiagnosis() async {
        guard !isDiagnosing else { return }
        isDiagnosing = true
        defer { isDiagnosing = false }
        var thresholds = DiagnosisThresholds()
        thresholds.lowDiskBytes = max(settings.lowDiskThreshold, thresholds.criticalDiskBytes)
        #if DEBUG
        let snapshot = DemoData.isEnabled ? DemoData.snapshot() : await SystemProbe.capture()
        #else
        let snapshot = await SystemProbe.capture()
        #endif
        diagnosis = VerdictEngine.diagnose(snapshot, thresholds: thresholds)
        disk = snapshot.disk
    }

    func process(_ pid: pid_t) -> ProcessSample? {
        diagnosis?.snapshot.processes.first { $0.pid == pid }
    }

    /// Demo data has made-up pids that may belong to real processes, so nothing acts on it.
    private var actionsDisabled: Bool {
        #if DEBUG
        DemoData.isEnabled
        #else
        false
        #endif
    }

    func perform(_ action: ProcessAction, on process: ProcessSample) {
        guard !actionsDisabled else { return }
        do {
            try ProcessController.perform(action, on: process)
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                await refreshDiagnosis()
            }
        } catch {
            message = error.description
        }
    }

    func perform(_ remedy: Remedy) {
        switch remedy {
        case .quit(let ref): if let process = process(ref.pid) { perform(.quit, on: process) }
        case .forceQuit(let ref): if let process = process(ref.pid) { perform(.forceQuit, on: process) }
        case .resume(let ref): if let process = process(ref.pid) { perform(.resume, on: process) }
        case .freeDisk:
            selection = .disk
            if lastScan == nil { Task { await scan() } }
        case .openBatterySettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        case .shutDownIdleSimulators: Task { await shutDownIdleSimulators() }
        case .stopOrphanedTools: requestStopOrphanedTools()
        case .showAgents: selection = .agents
        }
    }

    // MARK: Agents

    private(set) var agentActionInProgress: String?

    /// Shuts a simulator down only if a fresh look still finds it idle.
    func shutDown(_ simulator: BootedSimulator) async {
        guard !actionsDisabled else { return }
        await runAgentAction(String(localized: "Shutting down \(simulator.name)…")) { await AgentActions.shutDown(simulator) }
    }

    func shutDownIdleSimulators() async {
        guard !actionsDisabled else { return }
        for simulator in diagnosis?.snapshot.agents.idleSimulators ?? [] { await shutDown(simulator) }
    }

    /// Stops a tool and its children if it is still the same orphaned process.
    func stop(_ tool: ToolProcess) async {
        guard !actionsDisabled else { return }
        await runAgentAction(String(localized: "Stopping \(tool.label)…")) { await AgentActions.stop(tool) }
    }

    /// Tools waiting for the user to confirm a bulk stop. Several processes at once is
    /// easy to get wrong, so the list is shown before anything is signalled.
    var pendingToolStop: [ToolProcess]?

    func requestStopOrphanedTools() {
        let tools = diagnosis?.snapshot.agents.stoppableTools ?? []
        guard !tools.isEmpty else { return }
        selection = .agents
        pendingToolStop = tools
    }

    func confirmStop(_ tools: [ToolProcess]) async {
        guard !actionsDisabled else { return }
        pendingToolStop = nil
        for tool in tools { await stop(tool) }
    }

    private func runAgentAction(_ label: String, _ work: () async -> String?) async {
        agentActionInProgress = label
        if let problem = await work() { message = problem }
        agentActionInProgress = nil
        await refreshDiagnosis()
    }

    // MARK: Cleanup

    var isScanning: Bool { categories.values.contains(where: \.isScanning) }
    var isCleaning: Bool { cleaningProgress != nil }

    var reclaimableBytes: Int64 {
        categories.values.flatMap(\.cleanable).reduce(0) { $0 + $1.bytes }
    }

    var selectedBytes: Int64 {
        categories.values.flatMap(\.cleanable).filter { selectedItems.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    func state(for category: CleanupCategory) -> CategoryState {
        categories[category] ?? CategoryState()
    }

    func scan() async {
        guard !isScanning, !isCleaning else { return }
        #if DEBUG
        if DemoData.isEnabled { return }
        #endif
        for category in CleanupCategory.allCases {
            categories[category, default: CategoryState()].isScanning = true
        }
        let context = await ScanContext.capture(activityWindow: settings.activityWindow, projectRoots: settings.projectRoots)
        await withTaskGroup(of: (CleanupCategory, [CleanupItem]).self) { group in
            for category in CleanupCategory.allCases {
                group.addTask { (category, await CleanupScanner.discover(category, in: context)) }
            }
            for await (category, items) in group {
                let previouslyKnown = Set(categories[category]?.items.map(\.id) ?? [])
                categories[category] = CategoryState(items: items, isScanning: false, scanned: true)
                for item in items where item.isCleanable && !previouslyKnown.contains(item.id) && category.includedInAutomaticByDefault {
                    selectedItems.insert(item.id)
                }
            }
        }
        lastScan = .now
        disk = SystemProbe.disk()
    }

    func clean() async {
        guard !actionsDisabled else { return }
        let items = categories.values.flatMap(\.cleanable).filter { selectedItems.contains($0.id) }
        guard !items.isEmpty, !isCleaning else { return }
        cleaningProgress = CleanupExecutor.Progress(done: 0, total: items.count, current: String(localized: "Starting…"))
        guard let run = await CleanupExecutor.run(items, trigger: .manual, activityWindow: settings.activityWindow,
                                                  projectRoots: settings.projectRoots, progress: { progress in
            await MainActor.run { self.cleaningProgress = progress }
        }) else {
            cleaningProgress = nil
            message = String(localized: "Another clean-up is already running. Try again when it’s done.")
            return
        }
        HistoryStore.save(run)
        lastRun = run
        history = HistoryStore.load()
        cleaningProgress = nil
        let removed = Set(run.outcomes.filter { $0.result == .removed }.map(\.id))
        for category in CleanupCategory.allCases {
            categories[category]?.items.removeAll { removed.contains($0.id) }
        }
        selectedItems.subtract(removed)
        disk = SystemProbe.disk()
        await refreshDiagnosis()
    }

    func reloadHistory() {
        #if DEBUG
        if DemoData.isEnabled { return }
        #endif
        history = HistoryStore.load()
    }

    // MARK: Automation

    var automationActive: Bool { settings.lowDiskEnabled || settings.scheduleEnabled }

    func syncAgent() {
        do {
            try AgentRegistration.setEnabled(automationActive)
            if automationActive && settings.notify {
                Task { _ = await Notifier.requestAuthorization() }
            }
        } catch {
            message = String(localized: "Couldn’t register the background agent: \(error.localizedDescription)")
        }
        agentStatus = AgentRegistration.status
    }

    func refreshAgentStatus() {
        agentStatus = AgentRegistration.status
    }
}
