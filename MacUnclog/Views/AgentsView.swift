import SwiftUI

/// Everything coding agents have running: simulators, dev servers and builds, and the
/// sessions that own them. Only what no active session uses can be shut down from here.
struct AgentsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let agents = model.diagnosis?.snapshot.agents {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Summary(agents: agents)
                        SimulatorSection(simulators: agents.simulators, idleCount: agents.idleSimulators.count)
                        ToolSection(tools: agents.tools, sessions: agents.sessions, stoppable: agents.stoppableTools.count)
                        SessionSection(sessions: agents.sessions)
                    }
                    .padding(24)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            } else {
                ProgressView("Looking for agents, simulators and dev servers…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Agents")
        .navigationSubtitle(model.agentActionInProgress ?? String(localized: "Simulators, dev servers and builds that agents have started"))
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refreshDiagnosis() } }
                    .disabled(model.isDiagnosing)
            }
        }
    }
}

private struct Summary: View {
    let agents: AgentLoad

    var body: some View {
        HStack(spacing: 14) {
            let sessionCPU = Format.percent(agents.sessions.reduce(0) { $0 + $1.cpuPercent })
            let sessionMemory = Format.memory(agents.sessions.reduce(0) { $0 + $1.memoryBytes })
            SummaryTile(symbol: "person.2.wave.2", title: "Agent sessions", value: "\(agents.sessions.count)",
                        detail: String(localized: "\(sessionCPU) CPU · \(sessionMemory)"))
            SummaryTile(symbol: "iphone.gen3", title: "Simulators", value: "\(agents.simulators.count)",
                        detail: agents.idleSimulators.isEmpty ? Format.memory(agents.simulatorMemory)
                            : String(localized: "\(Format.memory(agents.simulatorMemory)) · \(agents.idleSimulators.count) idle"),
                        alert: !agents.idleSimulators.isEmpty)
            SummaryTile(symbol: "server.rack", title: "Tools", value: "\(agents.tools.count)",
                        detail: agents.stoppableTools.isEmpty ? String(localized: "All have an owner")
                            : String(localized: "\(agents.stoppableTools.count) left running"),
                        alert: !agents.stoppableTools.isEmpty)
        }
    }
}

private struct SummaryTile: View {
    let symbol: String
    let title: LocalizedStringKey
    let value: String
    let detail: String
    var alert = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(alert ? .orange : .accentColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Text(value).font(.title2.weight(.semibold)).contentTransition(.numericText())
                Text(detail).font(.caption).foregroundStyle(alert ? .orange : .secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.background.secondary, in: .rect(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct SectionHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
    }
}

private struct SimulatorSection: View {
    @Environment(AppModel.self) private var model
    let simulators: [BootedSimulator]
    let idleCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Booted simulators",
                          subtitle: "A simulator counts as idle when it has been on for 15 minutes with no load and no process refers to it.") {
                if idleCount > 0 {
                    Button(idleCount == 1 ? "Shut down the idle simulator" : "Shut down \(idleCount) idle simulators", systemImage: "power") {
                        Task { await model.shutDownIdleSimulators() }
                    }
                    .disabled(model.agentActionInProgress != nil)
                }
            }
            GroupedRows(empty: "No simulators are running.", items: simulators) { simulator in
                SimulatorRow(simulator: simulator)
            }
        }
    }
}

private struct SimulatorRow: View {
    @Environment(AppModel.self) private var model
    let simulator: BootedSimulator

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: simulator.name.hasPrefix("iPad") ? "ipad" : "iphone.gen3")
                .font(.title3)
                .foregroundStyle(simulator.idleReason == nil ? Color.accentColor : .secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(simulator.name)  \(Text(simulator.runtime).foregroundStyle(.secondary))")
                Text(status).font(.caption).foregroundStyle(simulator.idleReason == nil ? .secondary : Color.orange)
                    .lineLimit(1)
            }
            Spacer()
            Metrics(cpu: simulator.cpuPercent, memory: simulator.memoryBytes)
            Button("Shut down") { Task { await model.shutDown(simulator) } }
                .disabled(simulator.idleReason == nil || model.agentActionInProgress != nil)
                .help(simulator.idleReason == nil ? "In use, so MacUnclog leaves it alone" : "xcrun simctl shutdown \(simulator.udid)")
        }
        .contextMenu {
            Button("Copy UDID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(simulator.udid, forType: .string)
            }
        }
    }

    private var status: String {
        if let idle = simulator.idleReason { return String(localized: "Idle. \(idle)") }
        if let user = simulator.users.first { return String(localized: "In use by \(user.name) (PID \(user.pid))") }
        return String(localized: "In use, started \(Format.relative(simulator.bootedAt))")
    }
}

private struct ToolSection: View {
    @Environment(AppModel.self) private var model
    let tools: [ToolProcess]
    let sessions: [AgentSession]
    let stoppable: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Dev servers, emulators and builds",
                          subtitle: "You can stop tools that were left running after their session ended.") {
                if stoppable > 0 {
                    Button(stoppable == 1 ? "Stop the tool left running" : "Stop \(stoppable) tools left running", systemImage: "stop.circle") {
                        model.requestStopOrphanedTools()
                    }
                    .disabled(model.agentActionInProgress != nil)
                }
            }
            GroupedRows(empty: "No dev servers or builds are running.", items: tools) { tool in
                ToolRow(tool: tool, session: sessions.first { if case .session(let pid, _) = tool.owner { $0.pid == pid } else { false } })
            }
        }
    }
}

private struct ToolRow: View {
    @Environment(AppModel.self) private var model
    let tool: ToolProcess
    let session: AgentSession?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tool.isStoppable ? Color.orange : .accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tool.label)
                    if let place = tool.place { Text(place.title).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                    if !tool.ports.isEmpty {
                        Text(tool.ports.map { ":\($0)" }.joined(separator: " ")).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Text(ownerText).font(.caption).foregroundStyle(tool.isStoppable ? Color.orange : .secondary).lineLimit(1)
            }
            Spacer()
            Metrics(cpu: tool.cpuPercent, memory: tool.memoryBytes)
            Button("Stop") { Task { await model.stop(tool) } }
                .disabled(!tool.isStoppable || model.agentActionInProgress != nil)
                .help(stopHelp)
        }
        .contextMenu {
            if let folder = tool.folder {
                Button("Show folder in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder) }
            }
            if let port = tool.ports.first, let url = URL(string: "http://localhost:\(port)") {
                Button("Open localhost:\(port)") { NSWorkspace.shared.open(url) }
            }
        }
    }

    private var symbol: String {
        switch tool.kind {
        case .devServer: "server.rack"
        case .emulator: "flame"
        case .build: "hammer"
        case .watcher: "eye"
        case .daemon: "gearshape.2"
        }
    }

    private var stopHelp: String {
        guard tool.isStoppable else { return String(localized: "In use, so MacUnclog leaves it alone") }
        let count = tool.processIDs.count
        return count == 1 ? String(localized: "Stops 1 process") : String(localized: "Stops \(count) processes")
    }

    private var ownerText: String {
        let started = Format.relative(tool.startedAt)
        switch tool.owner {
        case .session(_, let kind):
            if let place = session?.place?.title {
                return String(localized: "\(kind.rawValue) session in \(place) · started \(started)")
            }
            return String(localized: "\(kind.rawValue) session · started \(started)")
        case .terminal:
            return String(localized: "Started from a terminal · \(started)")
        case .orphaned:
            if tool.kind == .daemon && !tool.isStoppable { return String(localized: "Shared daemon in use · started \(started)") }
            return String(localized: "Left running after its session ended · started \(started)")
        case .unknown:
            return String(localized: "Owner unknown · started \(started)")
        }
    }
}

private struct SessionSection: View {
    let sessions: [AgentSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Agent sessions",
                          subtitle: "Each session with everything it started. MacUnclog never ends a session.") { EmptyView() }
            GroupedRows(empty: "No Claude or Codex sessions are running.", items: sessions) { session in
                HStack(spacing: 12) {
                    Image(systemName: session.kind == .claude ? "sparkle" : "chevron.left.forwardslash.chevron.right")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "\(session.kind.rawValue)\(session.place.map { " · \($0.title)" } ?? "")")
                            .lineLimit(1).truncationMode(.middle)
                        Text(session.processCount == 1
                             ? String(localized: "Started \(Format.relative(session.startedAt)) · 1 process")
                             : String(localized: "Started \(Format.relative(session.startedAt)) · \(session.processCount) processes"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Metrics(cpu: session.cpuPercent, memory: session.memoryBytes)
                }
                .contextMenu {
                    if let folder = session.folder {
                        Button("Show folder in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder) }
                    }
                }
            }
        }
    }
}

private struct Metrics: View {
    let cpu: Double
    let memory: UInt64

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(Format.percent(cpu)) CPU").monospacedDigit()
                .foregroundStyle(cpu >= 80 ? .orange : .primary)
            Text(Format.memory(memory)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 80, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }
}

/// Rows in one rounded container with inset dividers, like a grouped Form section.
private struct GroupedRows<Item: Identifiable, Row: View>: View {
    let empty: LocalizedStringKey
    let items: [Item]
    @ViewBuilder var row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                Text(empty).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
            ForEach(items) { item in
                row(item).padding(.horizontal, 14).padding(.vertical, 10)
                if item.id != items.last?.id { Divider().padding(.leading, 52) }
            }
        }
        .background(.background.secondary, in: .rect(cornerRadius: 12, style: .continuous))
        .animation(.smooth, value: items.map(\.id))
    }
}
