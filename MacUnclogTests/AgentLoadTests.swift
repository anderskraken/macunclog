import Foundation
import Testing
@testable import MacUnclog

struct AgentLoadTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let udid = "D69D4A15-2637-499A-B935-19C402B0CE39"
    let otherUDID = "244D3A1C-E2F1-4ABF-91E9-746377477EA9"

    func row(_ pid: pid_t, _ ppid: pid_t, _ command: String, minutes: Double = 120) -> ProcessRow {
        ProcessRow(pid: pid, ppid: ppid, startedAt: now.addingTimeInterval(-minutes * 60), command: command)
    }

    func build(_ rows: [ProcessRow], cpu: [pid_t: Double] = [:], cwd: [pid_t: String] = [:], ports: [pid_t: [Int]] = [:],
               launches: [pid_t: AgentLaunch] = [:]) -> AgentLoad {
        var inputs = AgentLoadBuilder.Inputs(
            rows: [row(1, 0, "/sbin/launchd")] + rows,
            usage: Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, (cpu: cpu[$0.pid] ?? 0, memory: UInt64(100 << 20))) }),
            workingDirectories: cwd, ports: ports,
            simulatorNames: [udid: ("iPhone 18 Pro", "iOS 27.2"), otherUDID: ("iPad test", "iOS 27.2")], now: now)
        inputs.launches = launches
        return AgentLoadBuilder.build(inputs)
    }

    let claudeApp = "/Users/me/Library/Application Support/Claude/claude-code/2.1.321/abc/claude.app/Contents/MacOS/claude --output-format stream-json"

    @Test func devServerUnderALiveSessionBelongsToIt() {
        let load = build([
            row(10, 1, "/Applications/Claude.app/Contents/Helpers/disclaimer --pgroup --"),
            row(11, 10, claudeApp),
            row(12, 11, "/bin/zsh -c source /tmp/snapshot.sh && npx expo start --port 8091"),
            row(13, 12, "node /Users/me/dev/weather/.claude/worktrees/sung/node_modules/.bin/expo start --port 8091"),
        ], cwd: [11: "/Users/me/dev/weather/.claude/worktrees/sung", 13: "/Users/me/dev/weather/.claude/worktrees/sung"], ports: [13: [8091]])

        #expect(load.sessions.map(\.pid) == [11])
        #expect(load.sessions.first?.place?.title == "weather › sung")
        let tool = load.tools.first
        #expect(load.tools.count == 1)
        #expect(tool?.label == "Metro (Expo)")
        #expect(tool?.owner == .session(11, .claude))
        #expect(tool?.ports == [8091])
        #expect(tool?.isStoppable == false)
    }

    @Test func devServerWhoseSessionIsGoneIsOrphanedAndStoppable() {
        let load = build([
            row(20, 1, "node /Users/me/dev/app/node_modules/.bin/vite --port 5173"),
            row(21, 20, "/Users/me/dev/app/node_modules/@esbuild/darwin-arm64/bin/esbuild --service"),
        ], launches: [20: AgentLaunch(kind: .claude, sessionPID: 4444)])
        #expect(load.tools.first?.owner == .orphaned)
        #expect(load.tools.first?.isStoppable == true)
        #expect(load.tools.first?.processIDs.sorted() == [20, 21])
    }

    @Test func toolWithoutAnAgentMarkerIsNeverStoppable() {
        let load = build([
            row(25, 1, "/Applications/Zed.app/Contents/MacOS/zed-helper"),
            row(26, 1, "node /Users/me/dev/app/node_modules/.bin/vite --port 5173"),
        ])
        #expect(load.tools.first?.owner == .unknown)
        #expect(load.tools.first?.isStoppable == false)
    }

    @Test func detachedToolBelongsToItsLiveSession() {
        let load = build([
            row(27, 1, "/Users/me/.local/bin/claude"),
            row(28, 1, "nohup node node_modules/.bin/next dev"),
        ], launches: [28: AgentLaunch(kind: .claude, sessionPID: 27)])
        #expect(load.tools.first?.owner == .session(27, .claude))
        #expect(load.tools.first?.isStoppable == false)
    }

    @Test func codexToolWithoutPIDIsUnknownWhileAnyCodexRuns() {
        let tool = row(29, 1, "node node_modules/.bin/vite --port 5173")
        let launch: [pid_t: AgentLaunch] = [29: AgentLaunch(kind: .codex, sessionPID: nil)]
        #expect(build([row(30, 1, "/opt/homebrew/bin/codex"), tool], launches: launch).tools.first?.owner == .unknown)
        #expect(build([tool], launches: launch).tools.first?.owner == .orphaned)
    }

    @Test func claudeEnvironmentIsRecognised() {
        let launch = AgentLaunch.parse(environment: ["PATH=/bin", "CLAUDECODE=1", "CLAUDE_PID=61479"])
        #expect(launch == AgentLaunch(kind: .claude, sessionPID: 61479))
        #expect(AgentLaunch.parse(environment: ["PATH=/bin", "HOME=/Users/me"]) == nil)
    }

    @Test func terminalStartedToolsAreTheUsersOwn() {
        let load = build([
            row(30, 1, "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
            row(31, 30, "/bin/zsh -l"),
            row(32, 31, "node node_modules/.bin/next dev"),
        ])
        #expect(load.tools.first?.owner == .terminal)
        #expect(load.tools.first?.isStoppable == false)
    }

    @Test func busyGradleDaemonIsNotStoppedButAnIdleOneIs() {
        let gradle = "/usr/bin/java -cp gradle.jar org.gradle.launcher.daemon.bootstrap.GradleDaemon 8.14"
        let byAgent: [pid_t: AgentLaunch] = [40: AgentLaunch(kind: .claude, sessionPID: nil)]
        #expect(build([row(40, 1, gradle)], cpu: [40: 60], launches: byAgent).tools.first?.isStoppable == false)
        #expect(build([row(40, 1, gradle)], cpu: [40: 0], launches: byAgent).tools.first?.isStoppable == true)
    }

    @Test func subagentsCountAsOneSession() {
        let load = build([
            row(50, 1, "/Users/me/.local/bin/claude"),
            row(51, 50, "/Users/me/.local/bin/claude --print subagent"),
            row(52, 51, "/usr/bin/xcodebuild -scheme App test"),
        ])
        #expect(load.sessions.map(\.pid) == [50])
        #expect(load.sessions.first?.processCount == 3)
        #expect(load.tools.first?.owner == .session(50, .claude))
    }

    private func simulatorRows(minutes: Double) -> [ProcessRow] {
        [
            row(60, 1, "/Library/Developer/CoreSimulator/Volumes/iOS/launchd_sim /Users/me/Library/Developer/CoreSimulator/Devices/\(udid)/data/var/run/launchd_bootstrap.plist", minutes: minutes),
            row(61, 60, "/Library/Developer/CoreSimulator/Volumes/iOS/SpringBoard", minutes: minutes),
            row(70, 1, "/Library/Developer/CoreSimulator/Volumes/iOS/launchd_sim /Users/me/Library/Developer/CoreSimulator/Devices/\(otherUDID)/data/var/run/launchd_bootstrap.plist", minutes: minutes),
        ]
    }

    @Test func quietUnreferencedSimulatorIsIdle() {
        let load = build(simulatorRows(minutes: 120))
        #expect(load.simulators.count == 2)
        #expect(load.idleSimulators.count == 2)
        #expect(load.simulators.first { $0.udid == udid }?.name == "iPhone 18 Pro")
    }

    @Test func simulatorUsedByATestRunIsNotIdle() {
        let load = build(simulatorRows(minutes: 120) + [row(80, 1, "/usr/bin/xcodebuild test -destination id=\(udid)")])
        let simulator = load.simulators.first { $0.udid == udid }
        #expect(simulator?.idleReason == nil)
        #expect(simulator?.users.map(\.name) == ["xcodebuild"])
        #expect(load.idleSimulators.map(\.udid) == [otherUDID])
    }

    @Test func macUnclogNamingTheUDIDDoesNotCountAsAUser() {
        var inputs = AgentLoadBuilder.Inputs(
            rows: [row(1, 0, "/sbin/launchd")] + simulatorRows(minutes: 120) + [
                row(95, 1, "/bin/zsh -c MacUnclog --act shutdown-simulator \(udid)"),
                row(96, 95, "/Applications/MacUnclog.app/Contents/MacOS/MacUnclog --act shutdown-simulator \(udid)"),
            ],
            usage: [:], workingDirectories: [:], ports: [:], simulatorNames: [:], now: now)
        inputs.selfPID = 96
        #expect(AgentLoadBuilder.build(inputs).idleSimulators.contains { $0.udid == udid })
    }

    @Test func busyOrFreshlyBootedSimulatorIsNotIdle() {
        #expect(build(simulatorRows(minutes: 120), cpu: [61: 40]).idleSimulators.map(\.udid) == [otherUDID])
        #expect(build(simulatorRows(minutes: 5)).idleSimulators.isEmpty)
    }

    @Test func verdictNamesTheSimulatorsAndOffersShutdown() {
        var snapshot = VerdictEngineTests().snapshot()
        snapshot.agents = build(simulatorRows(minutes: 120) + [
            row(90, 1, "/x/launchd_sim /Users/me/Library/Developer/CoreSimulator/Devices/11111111-2222-3333-4444-555555555555/data", minutes: 120),
            row(91, 1, "/x/launchd_sim /Users/me/Library/Developer/CoreSimulator/Devices/66666666-2222-3333-4444-555555555555/data", minutes: 120),
        ])
        let diagnosis = VerdictEngine.diagnose(snapshot)
        #expect(diagnosis.verdict.headline.hasPrefix("Your Mac is slow because 4 simulators are running at once"))
        #expect(diagnosis.findings.first?.remedies.first == .shutDownIdleSimulators(4))
    }

    @Test func runtimeNamesAreReadable() {
        #expect(AgentProbe.prettyRuntime("com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4") == "iOS 27.2")
        let expected: TimeInterval = 2 * 86_400 + 3 * 3600 + 4 * 60 + 5
        #expect(AgentProbe.parseElapsed("2-03:04:05") == expected)
    }
}
