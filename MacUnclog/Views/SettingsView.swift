import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Automatic clean-up", systemImage: "clock.arrow.2.circlepath") { AutomationSettingsView() }
            Tab("General", systemImage: "gearshape") { GeneralSettingsView() }
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
