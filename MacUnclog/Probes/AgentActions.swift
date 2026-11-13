import Foundation

/// Shuts down simulators and stops tools, each time after a fresh look confirms that no
/// session uses them. Returns a message when it declined or failed.
enum AgentActions {
    static func shutDown(_ simulator: BootedSimulator) async -> String? {
        // A longer sample, so one busy moment in an idle simulator doesn't decide it.
        let fresh = await SystemProbe.capture(sampleInterval: .seconds(2)).agents
        guard fresh.idleSimulators.contains(where: { $0.udid == simulator.udid }) else {
            return String(localized: "\(simulator.name) is in use now and wasn’t shut down.")
        }
        let output = await Shell.run("/usr/bin/xcrun", ["simctl", "shutdown", simulator.udid], timeout: .seconds(60))
        let error = String(output.stderr.prefix(200))
        return output.succeeded ? nil : String(localized: "Couldn’t shut down \(simulator.name): \(error)")
    }

    static func stop(_ tool: ToolProcess) async -> String? {
        let fresh = await SystemProbe.capture(sampleInterval: .milliseconds(500)).agents
        guard let current = fresh.stoppableTools.first(where: { $0.pid == tool.pid }),
              abs(current.startedAt.timeIntervalSince(tool.startedAt)) < 5
        else { return String(localized: "\(tool.label) now has an owner or has already exited, so it wasn’t stopped.") }
        await ToolStopper.stop(current.processIDs)
        return nil
    }
}
