import Foundation
import Testing
@testable import MacUnclog

struct SimSlimTests {
    func simulator(_ udid: String, slim: Bool?) -> BootedSimulator {
        BootedSimulator(udid: udid, name: "iPhone", runtime: "iOS 27.2", bootedAt: .now - 3600, cpuPercent: 2,
                        memoryBytes: 4 << 30, users: [], idleReason: nil, slim: slim)
    }

    @Test func aSimulatorWithMostServicesOffCountsAsSlim() throws {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/MacUnclogTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func store(_ udid: String, disabled: Int, enabled: Int) throws {
            let folder = root.appendingPathComponent("com.apple.CoreSimulator.SimDevice.\(udid)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var entries: [String: Bool] = [:]
            for i in 0..<disabled { entries["com.apple.off\(i)"] = true }
            for i in 0..<enabled { entries["com.apple.on\(i)"] = false }
            try (entries as NSDictionary).write(to: folder.appendingPathComponent("disabled.plist"))
        }
        try store("SLIM", disabled: 170, enabled: 2)
        try store("STOCK", disabled: 3, enabled: 0)
        #expect(SimSlim.disabledCount(udid: "SLIM", root: root.path) == 170)
        #expect(SimSlim.disabledCount(udid: "STOCK", root: root.path) == 3)
        #expect(SimSlim.disabledCount(udid: "NEVER-BOOTED", root: root.path) == 0)
    }

    @Test func theSimulatorFindingOffersToSlimTheStockOnes() {
        var agents = AgentLoad()
        agents.simulators = [simulator("A", slim: false), simulator("B", slim: true), simulator("C", slim: false)]
        var snapshot = VerdictEngineTests().snapshot()
        snapshot.agents = agents
        let finding = VerdictEngine.diagnose(snapshot).findings.first { $0.kind == .simulators }
        #expect(finding?.remedies.contains(.slimSimulators(2)) == true)
        #expect(finding?.detail.contains("simslim") == true)
    }

    @Test func withoutSimslimNothingMentionsIt() {
        var agents = AgentLoad()
        agents.simulators = [simulator("A", slim: nil), simulator("B", slim: nil)]
        var snapshot = VerdictEngineTests().snapshot()
        snapshot.agents = agents
        let finding = VerdictEngine.diagnose(snapshot).findings.first { $0.kind == .simulators }
        #expect(finding?.remedies.contains { if case .slimSimulators = $0 { true } else { false } } == false)
        #expect(finding?.detail.contains("simslim") == false)
    }
}
