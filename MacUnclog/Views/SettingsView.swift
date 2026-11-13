import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Automatic clean-up", systemImage: "clock.arrow.2.circlepath") { AutomationSettingsView() }
            Tab("General", systemImage: "gearshape") { GeneralSettingsView() }
            Tab("Coding agents", systemImage: "terminal") { AgentSkillSettingsView() }
        }
        .frame(width: 560)
        .scenePadding()
    }
}

private struct AutomationSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var running = false
    @State private var busy = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Clean up when free space runs low", isOn: $model.settings.lowDiskEnabled)
                LabeledContent("Threshold") {
                    HStack(spacing: 8) {
                        Text("\(model.settings.lowDiskThresholdGB) GB").monospacedDigit()
                        Stepper("Threshold", value: $model.settings.lowDiskThresholdGB, in: 5...500, step: 5).labelsHidden()
                    }
                }
                .disabled(!model.settings.lowDiskEnabled)
            } footer: {
                Text("MacUnclog checks free space every 15 minutes. If it falls below the threshold, the app cleans up and notifies you, at most once every 6 hours.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Clean up on a schedule", isOn: $model.settings.scheduleEnabled)
                Picker("Frequency", selection: $model.settings.frequency) {
                    ForEach(ScheduleFrequency.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!model.settings.scheduleEnabled)
                Picker("Time", selection: $model.settings.hour) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
                .disabled(!model.settings.scheduleEnabled)
            }

            Section("Cleaned up automatically") {
                ForEach(CleanupCategory.allCases) { category in
                    Toggle(isOn: Binding(
                        get: { model.settings.includedCategories.contains(category) },
                        set: { on in
                            if on { model.settings.includedCategories.insert(category) } else { model.settings.includedCategories.remove(category) }
                        }
                    )) {
                        Label(category.title, systemImage: category.symbol)
                    }
                    .help(category.whatIsDeleted)
                }
            }

            Section {
                Toggle("Notify me about what was done", isOn: $model.settings.notify)
                LabeledContent("Background agent") {
                    HStack(spacing: 8) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(statusText)
                        if model.agentStatus == .requiresApproval {
                            Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                        }
                    }
                }
                LabeledContent("Last checked") {
                    Text(AgentState.load().lastCheck.map { Format.relative($0) } ?? String(localized: "Never"))
                }
                HStack {
                    Spacer()
                    Button {
                        running = true
                        Task {
                            if await BackgroundAgent.runOnce(force: .manual) == nil {
                                busy = true
                            }
                            model.reloadHistory()
                            running = false
                        }
                    } label: {
                        if running { ProgressView().controlSize(.small) } else { Text("Run automatic clean-up now") }
                    }
                    .disabled(running)
                }
            }
        }
        .formStyle(.grouped)
        // Shown here, since Settings often opens from the menu bar without the main window.
        .alert("Another clean-up is already running. Try again when it’s done.", isPresented: $busy) {
            Button("OK", role: .cancel) {}
        }
        .onAppear { model.refreshAgentStatus() }
    }

    private var statusText: String {
        switch model.agentStatus {
        case .enabled: String(localized: "Active")
        case .requiresApproval: String(localized: "Needs approval in System Settings")
        case .notRegistered: model.automationActive ? String(localized: "Not registered") : String(localized: "Off")
        case .notFound: String(localized: "Not found in the app")
        @unknown default: String(localized: "Unknown")
        }
    }

    private var statusColor: Color {
        switch model.agentStatus {
        case .enabled: .green
        case .requiresApproval: .orange
        default: .secondary
        }
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = AgentRegistration.launchAtLogin

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Open MacUnclog at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        AgentRegistration.launchAtLogin = on
                        launchAtLogin = AgentRegistration.launchAtLogin
                    }
            } footer: {
                Text("MacUnclog then sits in the menu bar and shows whether your Mac is doing fine.").foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Activity window") {
                    HStack(spacing: 8) {
                        Text(model.settings.activityWindowDays == 1 ? "1 day" : "\(model.settings.activityWindowDays) days").monospacedDigit()
                        Stepper("Activity window", value: $model.settings.activityWindowDays, in: 1...30).labelsHidden()
                    }
                }
            } footer: {
                Text("Build folders in a project are deleted only when no file in the project has changed within the window, no process is working in the project, no file in it is open and the folder is gitignored.")
                    .foregroundStyle(.secondary)
            }

            Section("Project folders") {
                ForEach(CleanupScanner.defaultProjectRoots(), id: \.self) { url in
                    LabeledContent(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), value: String(localized: "Default"))
                }
                ForEach(model.settings.extraProjectRoots, id: \.self) { path in
                    LabeledContent(path) {
                        Button("Remove", role: .destructive) {
                            model.settings.extraProjectRoots.removeAll { $0 == path }
                        }
                    }
                }
                Button("Add folder…") {
                    if let path = chooseFolder(), !model.settings.extraProjectRoots.contains(path) {
                        model.settings.extraProjectRoots.append(path)
                    }
                }
            }

            Section {
                ForEach(model.settings.protectedFolders, id: \.self) { path in
                    LabeledContent(path) {
                        Button("Remove", role: .destructive) {
                            model.settings.protectedFolders.removeAll { $0 == path }
                        }
                    }
                }
                Button("Add folder…") {
                    if let path = chooseFolder(), !model.settings.protectedFolders.contains(path) {
                        model.settings.protectedFolders.append(path)
                    }
                }
            } header: {
                Text("Protected folders")
            } footer: {
                Text("MacUnclog never deletes anything in these folders, in addition to Documents, Desktop, Downloads, Pictures, Movies, Music and iCloud Drive.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

private struct AgentSkillSettingsView: View {
    @State private var statuses: [AgentSkill.Agent: AgentSkill.Status] = [:]
    @State private var failure: String?
    /// An edited skill is overwritten or removed only after asking.
    @State private var replacing: (agent: AgentSkill.Agent, remove: Bool)?

    var body: some View {
        Form {
            Section {
                ForEach(AgentSkill.Agent.allCases) { agent in
                    let status = statuses[agent] ?? .notInstalled
                    LabeledContent {
                        HStack(spacing: 8) {
                            if status == .installed || status == .different {
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([agent.skillFile])
                                }
                                Button("Remove") {
                                    if status == .different { replacing = (agent, true) } else { run { try AgentSkill.remove(for: agent) } }
                                }
                            }
                            if status != .installed {
                                Button(status == .different ? "Update" : "Install") {
                                    if status == .different { replacing = (agent, false) } else { run { try AgentSkill.install(for: agent) } }
                                }
                                    .disabled(status == .agentMissing)
                            }
                        }
                    } label: {
                        Text(agent.title)
                        Text(description(of: status, for: agent))
                    }
                }
            } header: {
                Text("MacUnclog skill")
            } footer: {
                Text("With the skill, an agent checks your Mac before it boots a simulator or starts a big build, shuts down idle simulators and stops tools that ended sessions left running. It asks you before it quits an app or cleans up.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .confirmationDialog(
            replacing?.remove == true ? String(localized: "Remove the changed skill?") : String(localized: "Replace the changed skill?"),
            isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } })
        ) {
            if let replacing {
                Button(replacing.remove ? "Remove" : "Replace", role: .destructive) {
                    run { replacing.remove ? try AgentSkill.remove(for: replacing.agent) : try AgentSkill.install(for: replacing.agent) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let replacing {
                Text("The skill in \(Self.folder(of: replacing.agent)) isn’t the one this copy of MacUnclog installs. Any changes made to it will be lost.")
            }
        }
        .alert("That didn’t work", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: {
            Text(failure ?? "")
        }
    }

    private static func folder(of agent: AgentSkill.Agent) -> String {
        let path = agent.skillFile.deletingLastPathComponent().deletingLastPathComponent().path
        return path.hasPrefix(NSHomeDirectory()) ? "~" + path.dropFirst(NSHomeDirectory().count) : path
    }

    private func description(of status: AgentSkill.Status, for agent: AgentSkill.Agent) -> String {
        let folder = Self.folder(of: agent)
        let home = (folder as NSString).deletingLastPathComponent
        return switch status {
        case .agentMissing: String(localized: "No \(home) folder on this Mac")
        case .notInstalled: String(localized: "Not installed in \(folder)")
        case .installed: String(localized: "Installed in \(folder)")
        case .different: String(localized: "A different version is in \(folder)")
        }
    }

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { failure = (error as? AgentSkill.Failure)?.description ?? error.localizedDescription }
        reload()
    }

    private func reload() {
        let expected = AgentSkill.contents()
        statuses = Dictionary(uniqueKeysWithValues: AgentSkill.Agent.allCases.map { ($0, AgentSkill.status(of: $0, expected: expected)) })
    }
}
