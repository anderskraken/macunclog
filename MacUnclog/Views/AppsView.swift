import SwiftUI

/// Every app the user may quit, biggest first, so they can pick another one than the
/// suggestion. Apps they keep open are listed apart and never suggested.
struct AppsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var tabsFor: AppUsage?

    var body: some View {
        let apps = model.apps
        let suggested = apps.filter { model.isSuggested($0.app) }
        let kept = apps.filter { !model.isSuggested($0.app) }

        VStack(alignment: .leading, spacing: 0) {
            Text("Apps using memory")
                .font(.title2.weight(.semibold))
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 8)
            List {
                Section {
                    ForEach(suggested) { usage in
                        AppUsageRow(usage: usage, showTabs: { tabsFor = usage })
                    }
                }
                if !kept.isEmpty {
                    Section("Not suggested") {
                        ForEach(kept) { usage in
                            AppUsageRow(usage: usage, showTabs: { tabsFor = usage })
                        }
                    }
                }
            }
            .listStyle(.inset)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 600, height: 560)
        .sheet(item: $tabsFor) { usage in
            BrowserTabsSheet(usage: usage)
        }
        // The main window's alert would wait behind this sheet.
        .alert("That didn’t work", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
    }
}

private struct AppUsageRow: View {
    @Environment(AppModel.self) private var model
    let usage: AppUsage
    let showTabs: () -> Void

    var body: some View {
        let app = usage.app
        let canQuit = ProcessPolicy.allowedActions(for: app).contains(.quit)
        HStack(spacing: 10) {
            AppIconView(pid: app.pid, bundleIdentifier: app.bundleIdentifier, executablePath: app.executablePath, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).lineLimit(1)
                Text(usage.processCount == 1
                     ? Format.memory(usage.memory)
                     : String(localized: "\(Format.memory(usage.memory)) · \(usage.processCount) processes"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if usage.browser != nil {
                Button("Tabs…", action: showTabs)
            } else if canQuit {
                if model.restarting.contains(app.pid) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Restart") { Task { await model.restart(app) } }
                        .help("Quit \(app.name) and open it again. Apps that grow during the day give the memory back.")
                }
            }
            if canQuit {
                Button("Quit") { model.perform(.quit, on: app) }
            }
            Menu {
                if model.isSuggested(app) {
                    Button("Don’t suggest \(app.name)") { model.setSuggested(app, false) }
                } else {
                    Button("Suggest \(app.name) again") { model.setSuggested(app, true) }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(app.bundleIdentifier == nil)
            .accessibilityLabel("More actions for \(app.name)")
        }
        .padding(.vertical, 2)
    }
}

/// A browser's tabs, to close the ones the user doesn't need. Browsers don't say how much
/// memory each tab uses, so duplicates are the only ones MacUnclog can point out.
struct BrowserTabsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let usage: AppUsage

    @State private var tabs: [BrowserTab] = []
    @State private var selection: Set<String> = []
    @State private var loading = true
    @State private var closing = false
    @State private var failure: BrowserTabs.Failure?
    @State private var closed: Int?

    var body: some View {
        let duplicates = BrowserTabs.duplicates(in: tabs)
        let windows = Dictionary(grouping: tabs, by: \.window)
        let windowOrder = tabs.map(\.window).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tabs in \(usage.app.name)").font(.title2.weight(.semibold))
                if !loading && failure == nil {
                    Text(summary(windows: windowOrder.count, closedNow: closed))
                        .foregroundStyle(.secondary)
                }
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 8)

            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let failure {
                    VStack(spacing: 12) {
                        Text(failure.description)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        if case .notAllowed = failure {
                            Button("Open Automation settings") { NSWorkspace.shared.open(BrowserTabs.automationSettings) }
                        }
                        Button("Try again") { Task { await load() } }
                    }
                    .padding(30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(Array(windowOrder.enumerated()), id: \.element) { number, window in
                            Section(windowOrder.count > 1 ? String(localized: "Window \(number + 1)") : "") {
                                ForEach(windows[window] ?? []) { tab in
                                    TabRow(tab: tab, isDuplicate: duplicates.contains(tab.id), selection: $selection)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }

            HStack {
                Button("Select duplicates") { selection.formUnion(duplicates) }
                    .disabled(duplicates.isEmpty || closing)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(selection.count == 1 ? String(localized: "Close 1 tab") : String(localized: "Close \(selection.count) tabs")) {
                    Task { await closeSelected() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty || closing)
            }
            .padding(16)
        }
        .frame(width: 640, height: 600)
        .task { await load() }
    }

    private func summary(windows: Int, closedNow: Int?) -> String {
        let count = tabs.count == 1 ? String(localized: "1 tab") : String(localized: "\(tabs.count) tabs")
        let base = windows > 1 ? String(localized: "\(count) in \(windows) windows") : count
        guard let closedNow, closedNow > 0 else { return base }
        return closedNow == 1 ? String(localized: "\(base) · closed 1 tab") : String(localized: "\(base) · closed \(closedNow) tabs")
    }

    private func load() async {
        loading = true
        failure = nil
        // A Safari tab is known by its place, so an old tick could land on another tab.
        selection.removeAll()
        do {
            tabs = try await BrowserTabs.list(usage)
        } catch {
            failure = error
        }
        loading = false
    }

    private func closeSelected() async {
        guard !model.actionsDisabled else {
            failure = .failed(String(localized: "This window shows made-up demo data, so MacUnclog doesn’t change anything."))
            return
        }
        closing = true
        defer { closing = false }
        let chosen = tabs.filter { selection.contains($0.id) }
        do {
            let count = try await BrowserTabs.close(chosen, in: usage)
            closed = count
            await load()
            if count < chosen.count {
                let missed = chosen.count - count
                failure = .failed(missed == 1
                    ? String(localized: "1 tab wasn’t closed. It changed or moved after the list was made.")
                    : String(localized: "\(missed) tabs weren’t closed. They changed or moved after the list was made."))
            }
            await model.refreshDiagnosis()
        } catch {
            failure = error
        }
    }
}

private struct TabRow: View {
    let tab: BrowserTab
    let isDuplicate: Bool
    @Binding var selection: Set<String>

    var body: some View {
        Toggle(isOn: Binding(
            get: { selection.contains(tab.id) },
            set: { on in if on { selection.insert(tab.id) } else { selection.remove(tab.id) } }
        )) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.title.isEmpty ? tab.host : tab.title).lineLimit(1)
                    Text(tab.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if isDuplicate {
                    Text("Duplicate").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
    }
}
