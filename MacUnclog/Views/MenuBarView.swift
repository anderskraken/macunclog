import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let diagnosis = model.diagnosis {
                header(diagnosis.verdict)
                meters(diagnosis.snapshot)
                topProcesses(diagnosis.snapshot)
                agentRows(diagnosis.snapshot.agents)
            } else {
                ProgressView("Measuring…").frame(maxWidth: .infinity)
            }
            Divider()
            VStack(spacing: 2) {
                MenuRow(title: "Free up disk space…", symbol: "sparkles") { open(.disk) }
                MenuRow(title: "Agents and simulators…", symbol: "person.2.wave.2") { open(.agents) }
                MenuRow(title: "Open MacUnclog", symbol: "macwindow") { open(.overview) }
                SettingsLink {
                    Label("Settings…", systemImage: "gearshape")
                        .labelStyle(MenuLabelStyle())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(MenuRowStyle())
                MenuRow(title: "Quit MacUnclog", symbol: "power") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, -8)
        }
        .padding(14)
        .frame(width: 330)
    }

    private func header(_ verdict: Verdict) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: verdict.severity.verdictSymbol)
                .font(.title2)
                .foregroundStyle(verdict.severity.tint.gradient)
                .symbolEffect(.bounce, value: verdict.severity)
            VStack(alignment: .leading, spacing: 3) {
                Text(verdict.headline).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(verdict.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func meters(_ snapshot: SystemSnapshot) -> some View {
        HStack(spacing: 0) {
            MiniMeter(title: "Memory", value: Format.percent(snapshot.memory.usedFraction * 100),
                      fraction: snapshot.memory.usedFraction, tint: snapshot.memory.severity.tint)
            MiniMeter(title: "CPU", value: Format.percent(snapshot.cpu.usage * 100), fraction: snapshot.cpu.usage,
                      tint: snapshot.cpu.severity.tint)
            MiniMeter(title: "Disk", value: String(localized: "\(Format.bytes(snapshot.disk.available)) free"), fraction: snapshot.disk.usedFraction,
                      tint: snapshot.disk.severity(threshold: model.settings.lowDiskThreshold).tint)
        }
    }

    private func topProcesses(_ snapshot: SystemSnapshot) -> some View {
        let top = snapshot.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(3)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Using the most CPU").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(top)) { process in
                HStack(spacing: 8) {
                    AppIconView(pid: process.pid, bundleIdentifier: process.bundleIdentifier, executablePath: process.executablePath, size: 16)
                    Text(process.name).lineLimit(1)
                    Spacer()
                    Text(Format.percent(process.cpuPercent)).monospacedDigit().foregroundStyle(.secondary)
                    if ProcessPolicy.allowedActions(for: process).contains(.quit) {
                        Button {
                            model.perform(.quit, on: process)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Quit \(process.name)")
                        .accessibilityLabel("Quit \(process.name)")
                    }
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder
    private func agentRows(_ agents: AgentLoad) -> some View {
        let idle = agents.idleSimulators.count
        let orphaned = agents.stoppableTools.count
        if !agents.sessions.isEmpty || !agents.simulators.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(counts(agents))
                    .font(.caption).foregroundStyle(.secondary)
                if idle > 0 {
                    Button(idle == 1 ? "Shut down the idle simulator" : "Shut down \(idle) idle simulators", systemImage: "power") {
                        Task { await model.shutDownIdleSimulators() }
                    }
                }
                if orphaned > 0 {
                    Button(orphaned == 1 ? "Stop the tool left running" : "Stop \(orphaned) tools left running", systemImage: "stop.circle") {
                        model.requestStopOrphanedTools()
                        openWindow(id: "main")
                        NSApp.activate()
                    }
                }
            }
            .disabled(model.agentActionInProgress != nil)
        }
    }

    /// "2 agent sessions · 1 simulator · 3 tools"
    private func counts(_ agents: AgentLoad) -> String {
        let sessions = agents.sessions.count, simulators = agents.simulators.count, tools = agents.tools.count
        return [
            sessions == 1 ? String(localized: "1 agent session") : String(localized: "\(sessions) agent sessions"),
            simulators == 1 ? String(localized: "1 simulator") : String(localized: "\(simulators) simulators"),
            tools == 1 ? String(localized: "1 tool") : String(localized: "\(tools) tools"),
        ].joined(separator: " · ")
    }

    private func open(_ item: SidebarItem) {
        model.selection = item
        openWindow(id: "main")
        NSApp.activate()
        if item == .disk, model.lastScan == nil { Task { await model.scan() } }
    }
}

private struct MiniMeter: View {
    let title: LocalizedStringKey
    let value: String
    let fraction: Double
    let tint: Color

    var body: some View {
        VStack(spacing: 6) {
            RingMeter(fraction: fraction, tint: tint, lineWidth: 5)
                .frame(width: 38, height: 38)
            Text(value).font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

private struct MenuRow: View {
    let title: LocalizedStringKey
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(MenuLabelStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(MenuRowStyle())
    }
}

/// Fixed icon column so every row's text starts at the same x.
private struct MenuLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.frame(width: 18)
            configuration.title
        }
    }
}

/// Highlights on hover like a menu item.
private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRowBody(configuration: configuration)
    }

    private struct MenuRowBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(hovering ? Color.accentColor.opacity(configuration.isPressed ? 0.35 : 0.2) : .clear,
                            in: .rect(cornerRadius: 6, style: .continuous))
                .contentShape(.rect)
                .onHover { hovering = $0 }
        }
    }
}
