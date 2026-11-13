import Foundation
import Testing
@testable import MacUnclog

/// Starts real processes and acts on them through the same path as the app's buttons.
@MainActor
@Suite(.serialized)
struct ProcessActionTests {
    let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/MacUnclogTests-\(UUID().uuidString)")

    private func startSleeper() async throws -> Process {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let binary = folder.appendingPathComponent("sleeper")
        if !FileManager.default.fileExists(atPath: binary.path) {
            try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: binary.path)
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-", binary.path]
            try sign.run()
            sign.waitUntilExit()
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["300"]
        try process.run()
        try? await Task.sleep(for: .milliseconds(150))
        return process
    }

    private func sample(_ pid: pid_t) async throws -> ProcessSample {
        try #require(await SystemProbe.capture(sampleInterval: .milliseconds(100)).processes.first { $0.pid == pid })
    }

    private func waitForExit(_ process: Process) async -> Bool {
        for _ in 0..<50 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        return !process.isRunning
    }

    @Test func pauseResumeAndQuitARealProcess() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let sleeper = try await startSleeper()
        defer { if sleeper.isRunning { sleeper.terminate() } }

        var sample = try await sample(sleeper.processIdentifier)
        #expect(ProcessPolicy.allowedActions(for: sample).contains(.pause))

        try ProcessController.perform(.pause, on: sample)
        try await Task.sleep(for: .milliseconds(200))
        sample = try await self.sample(sleeper.processIdentifier)
        #expect(sample.state == .stopped)
        #expect(ProcessPolicy.allowedActions(for: sample).contains(.resume))

        try ProcessController.perform(.resume, on: sample)
        try await Task.sleep(for: .milliseconds(200))
        sample = try await self.sample(sleeper.processIdentifier)
        #expect(sample.state == .running)

        try ProcessController.perform(.quit, on: sample)
        #expect(await waitForExit(sleeper))
    }

    @Test func forceQuitARealProcess() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let sleeper = try await startSleeper()
        defer { if sleeper.isRunning { sleeper.terminate() } }
        try ProcessController.perform(.forceQuit, on: try await sample(sleeper.processIdentifier))
        #expect(await waitForExit(sleeper))
        #expect(sleeper.terminationReason == .uncaughtSignal)
    }

    @Test func launchdIsRefusedEvenWhenAsked() async throws {
        let launchd = try await sample(1)
        #expect(throws: ProcessController.Failure.self) { try ProcessController.perform(.forceQuit, on: launchd) }
    }
}
