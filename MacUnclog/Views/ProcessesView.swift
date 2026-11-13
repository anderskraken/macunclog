import SwiftUI

struct ProcessesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<pid_t> = []
    @State private var sortOrder = [KeyPathComparator(\ProcessSample.cpuPercent, order: .reverse)]
    @State private var search = ""
    @State private var showSystem = false
    @State private var pendingForceQuit: ProcessSample?

    private var processes: [ProcessSample] {
        let all = model.diagnosis?.snapshot.processes ?? []
        return all
            .filter { showSystem || $0.isOwnedByUser }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
    }

    private var selected: ProcessSample? {
        guard selection.count == 1, let pid = selection.first else { return nil }
        return model.process(pid)
    }

    var body: some View {
        Table(processes, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { process in
                HStack(spacing: 8) {
                    AppIconView(pid: process.pid, bundleIdentifier: process.bundleIdentifier, executablePath: process.executablePath)
                    Text(process.name).lineLimit(1)
                    if process.isNotResponding {
                        Text("Not responding").font(.caption).foregroundStyle(.red)
                    } else if process.state == .stopped {
                        Text("Paused").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .help(ProcessKnowledge.entry(for: process.name)?.explanation ?? process.executablePath ?? process.name)
            }
            .width(min: 200, ideal: 300)

            TableColumn("% CPU", value: \.cpuPercent) { process in
                Text(process.cpuPercent.formatted(.number.precision(.fractionLength(1))))
                    .monospacedDigit()
                    .foregroundStyle(process.cpuPercent >= 80 ? .orange : .primary)
            }
            .width(70)
            .alignment(.numeric)

            TableColumn("Memory", value: \.memoryBytes) { process in
                Text(Format.memory(process.memoryBytes))
                    .monospacedDigit()
            }
            .width(90)
            .alignment(.numeric)

            TableColumn("PID", value: \.pid) { process in
                Text(String(process.pid)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(60)
            .alignment(.numeric)
        }
        .contextMenu(forSelectionType: pid_t.self) { pids in
            if pids.count == 1, let pid = pids.first, let process = model.process(pid) {
                actionButtons(for: process)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search processes")
        .navigationTitle("Processes")
        .navigationSubtitle(processes.count == 1 ? Text("1 process") : Text("\(processes.count) processes"))
        .toolbar {
            ToolbarItem {
                Toggle("Show system processes", systemImage: "gearshape.2", isOn: $showSystem)
                    .help("Show processes owned by macOS and other users")
            }
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                let actions = selected.map { ProcessPolicy.allowedActions(for: $0) } ?? []
                Button("Quit", systemImage: "xmark.circle") {
                    if let selected { model.perform(.quit, on: selected) }
                }
                .disabled(!actions.contains(.quit))
                .help("Ask the process to quit")
                Button("Force quit", systemImage: "xmark.octagon") {
                    pendingForceQuit = selected
                }
                .disabled(!actions.contains(.forceQuit))
                .help("Stop the process immediately, without saving")
                if actions.contains(.resume) {
                    Button("Resume", systemImage: "play.circle") {
                        if let selected { model.perform(.resume, on: selected) }
                    }
                } else {
                    Button("Pause", systemImage: "pause.circle") {
                        if let selected { model.perform(.pause, on: selected) }
                    }
                    .disabled(!actions.contains(.pause))
                    .help("Freeze the process until you click Resume")
                }
            }
        }
        .confirmationDialog(
            "Force quit \(pendingForceQuit?.name ?? "")?",
            isPresented: Binding(get: { pendingForceQuit != nil }, set: { if !$0 { pendingForceQuit = nil } })
        ) {
            Button("Force quit", role: .destructive) {
                if let process = pendingForceQuit { model.perform(.forceQuit, on: process) }
            }
        } message: {
            Text("Unsaved changes will be lost.")
        }
        .overlay {
            if model.diagnosis == nil { ProgressView() }
        }
    }

    @ViewBuilder
    private func actionButtons(for process: ProcessSample) -> some View {
        let actions = ProcessPolicy.allowedActions(for: process)
        if actions.isEmpty {
            Text("MacUnclog doesn’t touch this process")
        }
        if actions.contains(.quit) { Button("Quit") { model.perform(.quit, on: process) } }
        if actions.contains(.forceQuit) { Button("Force quit…") { pendingForceQuit = process } }
        if actions.contains(.pause) { Button("Pause") { model.perform(.pause, on: process) } }
        if actions.contains(.resume) { Button("Resume") { model.perform(.resume, on: process) } }
        if let path = process.executablePath {
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
        }
    }
}
