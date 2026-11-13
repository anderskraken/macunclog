import Foundation
import Testing
@testable import MacUnclog

struct SimulatorRuntimeTests {
    let runtimes = Data("""
    {
      "A": {"identifier": "A", "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4",
            "version": "27.2", "build": "24B91016s", "sizeBytes": 9000000000, "deletable": true,
            "platformIdentifier": "com.apple.platform.iphonesimulator"},
      "B": {"identifier": "B", "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
            "version": "18.5", "build": "22F77", "sizeBytes": 8000000000, "deletable": true,
            "platformIdentifier": "com.apple.platform.iphonesimulator"}
    }
    """.utf8)

    let devices = Data("""
    {"devices": {
      "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4": [
        {"udid": "D1", "name": "Duo test", "state": "Shutdown", "isAvailable": true}
      ]
    }}
    """.utf8)

    private func runtimeItems(_ inventory: SimulatorInventory) async -> [CleanupItem] {
        let context = ScanContext(inUse: InUseSnapshot(entries: []), simulators: inventory, activityWindow: 86_400, projectRoots: [])
        return await CleanupScanner.discover(.simulatorRuntimes, in: context)
    }

    @Test func runtimeUsedByASimulatorIsNeverOffered() async {
        let items = await runtimeItems(SimulatorInventory.parse(devicesJSON: devices, runtimesJSON: runtimes))
        let deviceSpecific = items.first { $0.id == "runtime:A" }
        #expect(deviceSpecific?.blocked == .runtimeInUse(devices: 1))
        #expect(deviceSpecific?.isCleanable == false)
        #expect(items.first { $0.id == "runtime:B" }?.isCleanable == true)
    }

    @Test func runtimeUsedOnlyInAProjectDeviceSetIsNeverOffered() async throws {
        let set = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/MacUnclogTests-\(UUID().uuidString)/.ios27/devices")
        let device = set.appendingPathComponent("ABCD")
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: set.deletingLastPathComponent().deletingLastPathComponent()) }
        try (["runtime": "com.apple.CoreSimulator.SimRuntime.iOS-18-5", "name": "Old"] as NSDictionary).write(to: device.appendingPathComponent("device.plist"))

        var inventory = SimulatorInventory.parse(devicesJSON: devices, runtimesJSON: runtimes)
        inventory.otherSetUsers = SimulatorInventory.runtimeUsers(inSets: [set])
        let items = await runtimeItems(inventory)
        #expect(items.first { $0.id == "runtime:B" }?.blocked == .runtimeInUse(devices: 1))
    }

    @Test func unreadableDeviceListOffersNoRuntimes() async {
        let items = await runtimeItems(SimulatorInventory.parse(devicesJSON: Data("not json".utf8), runtimesJSON: runtimes))
        #expect(items.isEmpty)
    }
}

struct VerdictEngineTests {
    func snapshot(
        pressure: MemoryPressure = .normal, freeDisk: Int64 = 200 * Format.gigabyte,
        processes: [ProcessSample] = [], cpuUsage: Double = 0.2, thermal: ThermalLevel = .nominal
    ) -> SystemSnapshot {
        SystemSnapshot(
            takenAt: .now,
            memory: MemorySnapshot(total: 32 << 30, appMemory: 10 << 30, wired: 2 << 30, compressed: 1 << 30, cached: 4 << 30,
                                   free: 4 << 30, swapUsed: 3 << 30, swapTotal: 4 << 30, pressure: pressure, swapPagesPerSecond: 0),
            cpu: CPUSnapshot(usage: cpuUsage, load1: 2, load5: 2, cores: 10),
            disk: DiskSnapshot(total: 1000 * Format.gigabyte, available: freeDisk),
            thermal: thermal,
            power: PowerSnapshot(onBattery: false, batteryPercent: nil, lowPowerMode: false),
            processes: processes,
            uptime: 3600
        )
    }

    func process(_ name: String, cpu: Double = 1, memory: UInt64 = 100 << 20, notResponding: Bool = false, app: Bool = true) -> ProcessSample {
        ProcessSample(pid: 4242, name: name, executablePath: "/Applications/\(name).app/Contents/MacOS/\(name)",
                      bundleIdentifier: nil, isRegularApp: app, isOwnedByUser: true, isNotResponding: notResponding,
                      state: .running, cpuPercent: cpu, memoryBytes: memory)
    }

    @Test func healthyMacGetsAGoodVerdict() {
        let diagnosis = VerdictEngine.diagnose(snapshot())
        #expect(diagnosis.verdict.severity == .good)
        #expect(diagnosis.verdict.headline == "Your Mac is fine")
    }

    @Test func criticalMemoryPressureLeadsTheVerdictWithAQuitRemedy() {
        let diagnosis = VerdictEngine.diagnose(snapshot(pressure: .critical, processes: [process("Chrome", memory: 9 << 30)]))
        #expect(diagnosis.verdict.severity == .critical)
        #expect(diagnosis.verdict.headline.hasPrefix("Your Mac is slow because memory is full"))
        #expect(diagnosis.findings.first?.remedies.contains(.quit(ProcessRef(pid: 4242, name: "Chrome"))) == true)
    }

    @Test func memoryAdviceNamesWholeAppsAndNeverAnAgentHost() {
        let claude = ProcessSample(pid: 10, name: "Claude", executablePath: "/Applications/Claude.app/Contents/MacOS/Claude",
                                   bundleIdentifier: "com.anthropic.claudefordesktop", isRegularApp: true, isOwnedByUser: true,
                                   isNotResponding: false, state: .running, cpuPercent: 1, memoryBytes: 6 << 30)
        let teams = ProcessSample(pid: 20, name: "Teams", executablePath: "/Applications/Teams.app/Contents/MacOS/Teams",
                                  bundleIdentifier: "com.microsoft.teams2", isRegularApp: true, isOwnedByUser: true,
                                  isNotResponding: false, state: .running, cpuPercent: 1, memoryBytes: 1 << 30)
        let helper = ProcessSample(pid: 21, name: "Teams WebView Helper", executablePath: "/Applications/Teams.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper",
                                   bundleIdentifier: nil, isRegularApp: false, isOwnedByUser: true,
                                   isNotResponding: false, state: .running, cpuPercent: 1, memoryBytes: 3 << 30)
        let diagnosis = VerdictEngine.diagnose(snapshot(pressure: .warning, processes: [claude, teams, helper]))
        let pressure = diagnosis.findings.first { $0.kind == .memoryPressure }
        #expect(pressure?.remedies == [.quit(ProcessRef(pid: 20, name: "Teams"))])
        #expect(diagnosis.findings.contains { $0.title == "Teams is using \(Format.memory(4 << 30)) of memory" })
        #expect(!diagnosis.findings.contains { $0.kind == .memoryHog(10) })
    }

    @Test func lowDiskBelowThresholdOffersCleanup() {
        var thresholds = DiagnosisThresholds()
        thresholds.lowDiskBytes = 30 * Format.gigabyte
        let diagnosis = VerdictEngine.diagnose(snapshot(freeDisk: 25 * Format.gigabyte), thresholds: thresholds)
        let finding = diagnosis.findings.first { $0.kind == .lowDisk }
        #expect(finding?.severity == .warning)
        #expect(finding?.remedies == [.freeDisk])
    }

    @Test func hungAppIsCriticalAndOffersForceQuitOnly() {
        let diagnosis = VerdictEngine.diagnose(snapshot(processes: [process("Pages", notResponding: true)]))
        let finding = diagnosis.findings.first
        #expect(finding?.kind == .notResponding(4242))
        #expect(finding?.remedies == [.forceQuit(ProcessRef(pid: 4242, name: "Pages"))])
    }

    @Test func oneBusyCoreOnAnIdleMacIsOnlyANotice() {
        let diagnosis = VerdictEngine.diagnose(snapshot(processes: [process("node", cpu: 98, app: false)], cpuUsage: 0.15))
        #expect(diagnosis.findings.first?.severity == .notice)
        #expect(diagnosis.verdict.severity == .notice)
    }

    @Test func thermalThrottlingIsAWarning() {
        let diagnosis = VerdictEngine.diagnose(snapshot(thermal: .serious))
        #expect(diagnosis.verdict.headline.contains("throttled"))
    }
}

struct ProcessPolicyTests {
    func sample(name: String = "tool", owned: Bool = true, app: Bool = false, path: String? = "/Users/me/bin/tool",
                state: ProcessSample.RunState = .running) -> ProcessSample {
        ProcessSample(pid: 999, name: name, executablePath: path, bundleIdentifier: nil, isRegularApp: app,
                      isOwnedByUser: owned, isNotResponding: false, state: state, cpuPercent: 0, memoryBytes: 0)
    }

    @Test func othersProcessesAreUntouchable() {
        #expect(ProcessPolicy.allowedActions(for: sample(owned: false)).isEmpty)
    }

    @Test func sessionCriticalProcessesAreUntouchable() {
        #expect(ProcessPolicy.allowedActions(for: sample(name: "WindowServer")).isEmpty)
        #expect(ProcessPolicy.allowedActions(for: sample(name: "Finder", app: true)).isEmpty)
        #expect(ProcessPolicy.allowedActions(for: sample(name: "cloudd", path: "/System/Library/PrivateFrameworks/x/cloudd")).isEmpty)
    }

    @Test func appsCanBeQuitButNotPaused() {
        #expect(ProcessPolicy.allowedActions(for: sample(name: "Slack", app: true)) == [.quit, .forceQuit])
    }

    @Test func stoppedToolsCanBeResumed() {
        #expect(ProcessPolicy.allowedActions(for: sample(state: .stopped)).contains(.resume))
        #expect(ProcessPolicy.allowedActions(for: sample()).contains(.pause))
    }
}

struct AgentDecisionTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    var lowDiskOn: AutomationSettings {
        var settings = AutomationSettings()
        settings.lowDiskEnabled = true
        return settings
    }

    @Test func nothingHappensUntilTheUserTurnsAutomationOn() {
        let settings = AutomationSettings()
        #expect(settings.lowDiskEnabled == false && settings.scheduleEnabled == false)
        #expect(!settings.includedCategories.contains(.projectBuilds))
        #expect(BackgroundAgent.decide(settings: settings, state: AgentState(), freeBytes: Format.gigabyte, now: now) == .nothing)
    }

    @Test func lowDiskTriggersCleanup() {
        let decision = BackgroundAgent.decide(settings: lowDiskOn, state: AgentState(), freeBytes: 15 * Format.gigabyte, now: now)
        #expect(decision == .clean(.lowDisk))
    }

    @Test func lowDiskCooldownPreventsALoop() {
        var state = AgentState()
        state.lastLowDiskRun = now.addingTimeInterval(-3600)
        let decision = BackgroundAgent.decide(settings: lowDiskOn, state: state, freeBytes: 15 * Format.gigabyte, now: now)
        #expect(decision == .nothing)
    }

    @Test func plentyOfSpaceAndNoScheduleDoesNothing() {
        let decision = BackgroundAgent.decide(settings: AutomationSettings(), state: AgentState(), freeBytes: 90 * Format.gigabyte, now: now)
        #expect(decision == .nothing)
    }

    @Test func dailyRunAtSixPMCatchesUpAfterSleepInsteadOfSkippingADay() {
        var settings = AutomationSettings()
        settings.scheduleEnabled = true
        settings.frequency = .daily
        settings.hour = 18
        let lastRun = calendar.date(from: DateComponents(year: 2027, month: 1, day: 10, hour: 18, minute: 5))!
        let next = BackgroundAgent.nextScheduledRun(settings: settings, last: lastRun, now: lastRun, calendar: calendar)
        #expect(next == calendar.date(from: DateComponents(year: 2027, month: 1, day: 11, hour: 18))!)
        let wakeNextMorning = calendar.date(from: DateComponents(year: 2027, month: 1, day: 12, hour: 8))!
        var state = AgentState()
        state.lastScheduledRun = lastRun
        #expect(BackgroundAgent.decide(settings: settings, state: state, freeBytes: 90 * Format.gigabyte, now: wakeNextMorning, calendar: calendar) == .clean(.schedule))
    }

    @Test func weeklyScheduleRunsWhenDueAndAfterTheChosenHour() {
        var settings = AutomationSettings()
        settings.scheduleEnabled = true
        settings.hour = 0
        var state = AgentState()
        state.lastScheduledRun = now.addingTimeInterval(-8 * 86_400)
        #expect(BackgroundAgent.decide(settings: settings, state: state, freeBytes: 90 * Format.gigabyte, now: now, calendar: calendar) == .clean(.schedule))
        state.lastScheduledRun = now.addingTimeInterval(-2 * 86_400)
        #expect(BackgroundAgent.decide(settings: settings, state: state, freeBytes: 90 * Format.gigabyte, now: now, calendar: calendar) == .nothing)
    }
}

struct ExternalReferenceTests {
    @Test func pathsAreFoundInCommandsAndArguments() {
        let home = NSHomeDirectory()
        let paths = ExternalReferences.absolutePaths(inText: "node \"\(home)/dev/my-mcp/dist/index.js\" --root=~/dev/notes")
        #expect(paths == ["\(home)/dev/my-mcp/dist/index.js", "\(home)/dev/notes"])
    }

    @Test func aProjectUsedFromOutsideIsReported() {
        let refs = ExternalReferences(references: [.init(path: "/Users/me/dev/tool/target/release/tool", source: "~/.local/bin")])
        #expect(refs.blockReason(for: "/Users/me/dev/tool") == .usedFromOutside("~/.local/bin"))
        #expect(refs.blockReason(for: "/Users/me/dev/Tool") == .usedFromOutside("~/.local/bin"))
        #expect(refs.blockReason(for: "/Users/me/dev/tools") == nil)
    }

    @Test func anUnreadableProjectConfigBlocksOnlyThatProject() {
        let refs = ExternalReferences(references: [.init(path: "/Users/me/dev/a", source: "~/dev/a/.mcp.json", unreadable: true)])
        #expect(refs.blockReason(for: "/Users/me/dev/a") == .configUnreadable("~/dev/a/.mcp.json"))
        #expect(refs.blockReason(for: "/Users/me/dev/b") == nil)
        let global = ExternalReferences(references: [], unreadable: "~/.claude.json")
        #expect(global.blockReason(for: "/Users/me/dev/b") == .configUnreadable("~/.claude.json"))
    }

    @Test func referencesResolveThroughSymlinks() throws {
        let base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/MacUnclogTests-\(UUID().uuidString)")
        let real = base.appendingPathComponent("Developer/tool")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("dev"), withDestinationURL: base.appendingPathComponent("Developer"))
        let viaLink = base.appendingPathComponent("dev/tool/dist/index.js").path
        #expect(ExternalReferences.resolve(viaLink) == PathGuard.normalized(real.resolvingSymlinksInPath().path) + "/dist/index.js")
    }

    @Test func onlyDanglingConfigLinksAreSkipped() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MacUnclogTests-\(UUID().uuidString)")
        let locked = folder.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: locked.appendingPathComponent("mcp.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let dangling = folder.appendingPathComponent("dangling.json")
        let unreadable = folder.appendingPathComponent("unreadable.json")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: folder.appendingPathComponent("missing.json"))
        try FileManager.default.createSymbolicLink(at: unreadable, withDestinationURL: locked.appendingPathComponent("mcp.json"))

        let offline = folder.appendingPathComponent("offline.json")
        try FileManager.default.createSymbolicLink(at: offline, withDestinationURL: URL(fileURLWithPath: "/Volumes/MacUnclogNoSuchDisk/mcp.json"))

        #expect(ExternalReferences.isDanglingLink(dangling.path))
        #expect(!ExternalReferences.isDanglingLink(offline.path))
        #expect(!ExternalReferences.isDanglingLink(unreadable.path))
        #expect(ExternalReferences.pathsInMCPServers(jsonAt: unreadable.path) == nil)
    }

    @Test func configsWithCommentsWhitespaceOrGarbageAreHandled() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MacUnclogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func write(_ name: String, _ text: String) throws -> String {
            let file = folder.appendingPathComponent(name)
            try Data(text.utf8).write(to: file)
            return file.path
        }
        let jsonc = try write("zed.json", """
            { // Zed settings
              "context_servers": { "x": { "command": "/Users/me/dev/mcp/run.sh", }, },
            }
            """)
        #expect(ExternalReferences.pathsInMCPServers(jsonAt: jsonc) == ["/Users/me/dev/mcp/run.sh"])
        #expect(ExternalReferences.pathsInMCPServers(jsonAt: try write("blank.json", " \n")) == [])
        #expect(ExternalReferences.pathsInMCPServers(jsonAt: try write("broken.json", "{ not json")) == nil)
    }
}
