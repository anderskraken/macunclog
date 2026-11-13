import Foundation
import Testing
@testable import MacUnclog

struct SustainedCPUTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func snapshot(at offset: TimeInterval, processes: [ProcessSample], usage: Double = 0.95) -> SystemSnapshot {
        SystemSnapshot(
            takenAt: start + offset,
            memory: MemorySnapshot(total: 32 << 30, appMemory: 10 << 30, wired: 2 << 30, compressed: 0, cached: 4 << 30,
                                   free: 10 << 30, swapUsed: 0, swapTotal: 0, pressure: .normal, swapPagesPerSecond: 0),
            cpu: CPUSnapshot(usage: usage, load1: 9, load5: 8, cores: 10),
            disk: DiskSnapshot(total: 1000 * Format.gigabyte, available: 500 * Format.gigabyte),
            thermal: .nominal,
            power: PowerSnapshot(onBattery: false, batteryPercent: nil, lowPowerMode: false),
            processes: processes,
            uptime: 3600
        )
    }

    func node(cpu: Double, started: UInt64 = 1) -> ProcessSample {
        var sample = ProcessSample(pid: 4242, name: "node", executablePath: "/opt/homebrew/bin/node", bundleIdentifier: nil,
                                   isRegularApp: false, isOwnedByUser: true, isNotResponding: false, state: .running,
                                   cpuPercent: cpu, memoryBytes: 200 << 20)
        sample.startSeconds = started
        return sample
    }

    /// Records the measurements in order and diagnoses the last one.
    func diagnose(_ snapshots: [SystemSnapshot]) -> Diagnosis {
        var streaks = CPUStreaks.empty
        for snapshot in snapshots { streaks.record(snapshot, threshold: DiagnosisThresholds().cpuHogPercent) }
        var last = snapshots.last!
        last.cpuStreaks = streaks
        return VerdictEngine.diagnose(last)
    }

    @Test func aSpikeIsANoticeAndStaysOutOfTheHeadline() {
        let diagnosis = diagnose([snapshot(at: 0, processes: [node(cpu: 400)])])
        let finding = diagnosis.findings.first { $0.kind == .cpuHog(4242) }
        #expect(finding?.severity == .notice)
        #expect(finding?.title.hasSuffix("right now") == true)
        #expect(finding?.sustainedSeconds == nil)
        #expect(diagnosis.verdict.severity == .notice)
    }

    @Test func aLoadThatLastsIsAWarningWithItsDuration() {
        let diagnosis = diagnose([
            snapshot(at: 0, processes: [node(cpu: 390)]),
            snapshot(at: 10, processes: [node(cpu: 410)]),
            snapshot(at: 20, processes: [node(cpu: 400)]),
        ])
        let finding = diagnosis.findings.first { $0.kind == .cpuHog(4242) }
        #expect(finding?.severity == .warning)
        #expect(finding?.sustainedSeconds == 20)
        #expect(diagnosis.verdict.headline.contains("node has kept"))
    }

    @Test func aShortDipFromContentionDoesNotEndTheStreak() {
        let diagnosis = diagnose([
            snapshot(at: 0, processes: [node(cpu: 90)]), snapshot(at: 6, processes: [node(cpu: 68)]), snapshot(at: 16, processes: [node(cpu: 160)]),
        ])
        #expect(diagnosis.findings.first { $0.kind == .cpuHog(4242) }?.sustainedSeconds == 16)
    }

    @Test func twoSpikesWithModerateLoadBetweenThemDoNotJoin() {
        let diagnosis = diagnose([
            snapshot(at: 0, processes: [node(cpu: 400)]), snapshot(at: 10, processes: [node(cpu: 60)]),
            snapshot(at: 20, processes: [node(cpu: 60)]), snapshot(at: 30, processes: [node(cpu: 400)]),
        ])
        #expect(diagnosis.findings.first { $0.kind == .cpuHog(4242) }?.severity == .notice)
    }

    @Test func aDipFollowedByALongGapEndsTheStreak() {
        let diagnosis = diagnose([
            snapshot(at: 0, processes: [node(cpu: 400)]), snapshot(at: 10, processes: [node(cpu: 60)]), snapshot(at: 40, processes: [node(cpu: 400)]),
        ])
        #expect(diagnosis.findings.first { $0.kind == .cpuHog(4242) }?.severity == .notice)
    }

    @Test func aSteadyLoadAtTheSlowRefreshKeepsItsStreak() {
        let diagnosis = diagnose([snapshot(at: 0, processes: [node(cpu: 400)]), snapshot(at: 30, processes: [node(cpu: 400)])])
        #expect(diagnosis.findings.first { $0.kind == .cpuHog(4242) }?.sustainedSeconds == 30)
    }

    @Test func twoMeasurementsCloseTogetherAreNotEnough() {
        let diagnosis = diagnose([snapshot(at: 0, processes: [node(cpu: 400)]), snapshot(at: 5, processes: [node(cpu: 400)])])
        #expect(diagnosis.findings.first { $0.kind == .cpuHog(4242) }?.severity == .notice)
    }

    @Test func aDipALongGapOrANewProcessStartsTheStreakAgain() {
        let busy = node(cpu: 400)
        let dipped = diagnose([
            snapshot(at: 0, processes: [busy]), snapshot(at: 10, processes: [node(cpu: 20)]), snapshot(at: 20, processes: [busy]),
        ])
        #expect(dipped.findings.first { $0.kind == .cpuHog(4242) }?.severity == .notice)

        let slept = diagnose([snapshot(at: 0, processes: [busy]), snapshot(at: 600, processes: [busy])])
        #expect(slept.findings.first { $0.kind == .cpuHog(4242) }?.severity == .notice)

        let reused = diagnose([snapshot(at: 0, processes: [busy]), snapshot(at: 20, processes: [node(cpu: 400, started: 2)])])
        #expect(reused.findings.first { $0.kind == .cpuHog(4242) }?.severity == .notice)
    }

    @Test func aFullCPUOnlyLeadsTheVerdictOnceItLasts() {
        let quiet = [node(cpu: 30)]
        let spike = diagnose([snapshot(at: 0, processes: quiet)])
        #expect(spike.findings.first { $0.kind == .cpuSaturated }?.severity == .notice)

        let lasting = diagnose([snapshot(at: 0, processes: quiet), snapshot(at: 30, processes: quiet)])
        #expect(lasting.findings.first { $0.kind == .cpuSaturated }?.severity == .warning)
        #expect(lasting.verdict.headline.contains("fully loaded"))
    }

    @Test func aBuildOfShortLivedCompilersStillCountsOnceTheCPUStaysFull() {
        func clang(_ pid: pid_t) -> ProcessSample {
            ProcessSample(pid: pid, name: "clang", executablePath: "/usr/bin/clang", bundleIdentifier: nil,
                                   isRegularApp: false, isOwnedByUser: true, isNotResponding: false, state: .running,
                                   cpuPercent: 100, memoryBytes: 100 << 20)
        }
        let diagnosis = diagnose([
            snapshot(at: 0, processes: [clang(1)]), snapshot(at: 10, processes: [clang(2)]), snapshot(at: 20, processes: [clang(3)]),
        ])
        #expect(diagnosis.findings.first { $0.kind == .cpuSaturated }?.severity == .warning)
        #expect(diagnosis.verdict.severity == .warning)
    }

    @Test func aSpikeSaysSoInTheSummary() {
        let diagnosis = diagnose([snapshot(at: 0, processes: [node(cpu: 400)])])
        #expect(diagnosis.verdict.summary.hasPrefix("The CPU is busy right now"))
    }

    @Test func theJSONReportUsesFixedIdentifiers() throws {
        let diagnosis = diagnose([snapshot(at: 0, processes: [node(cpu: 400)]), snapshot(at: 20, processes: [node(cpu: 400)])])
        let json = Report.json(Report.DiagnosisReport(diagnosis, measuredSeconds: 20))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["schema"] as? Int == 1)
        let findings = try #require(object["findings"] as? [[String: Any]])
        let hog = try #require(findings.first { $0["kind"] as? String == "cpuHog" })
        #expect(hog["pid"] as? Int == 4242)
        #expect(hog["severity"] as? String == "warning")
        #expect(hog["sustainedSeconds"] as? Int == 20)
        let remedies = try #require(hog["remedies"] as? [[String: Any]])
        #expect(remedies.contains { $0["command"] as? String == "--act quit 4242" })
    }
}

struct AgentSkillTests {
    let text = "MU=/Applications/MacUnclog.app/Contents/MacOS/MacUnclog\nrest"

    @Test func aCopyInApplicationsKeepsTheDefaultPath() {
        #expect(AgentSkill.pointed(text, at: "/Applications/MacUnclog.app/Contents/MacOS/MacUnclog") == text)
        #expect(AgentSkill.pointed(text, at: "/Applications/Setapp/MacUnclog.app/Contents/MacOS/MacUnclog").hasPrefix("MU='/Applications/Setapp/"))
    }

    @Test func anotherCopyIsQuotedForTheShell() {
        let pointed = AgentSkill.pointed(text, at: "/Users/me/Kim's apps/MacUnclog.app/Contents/MacOS/MacUnclog")
        #expect(pointed.hasPrefix("MU='/Users/me/Kim'\\''s apps/MacUnclog.app/Contents/MacOS/MacUnclog'\n"))
    }

    @Test func theBundledSkillIsThere() {
        #expect(AgentSkill.contents()?.contains("name: macunclog") == true)
    }
}
