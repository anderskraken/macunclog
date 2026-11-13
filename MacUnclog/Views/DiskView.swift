import SwiftUI

struct DiskView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                StorageHeader()
                if let progress = model.cleaningProgress {
                    CleaningProgressView(progress: progress)
                } else if let run = model.lastRun {
                    RunResultBanner(run: run)
                }
                if model.lastScan == nil && !model.isScanning {
                    ScanPrompt()
                } else {
                    CategoryList()
                    PersonalFilesSection()
                }
                AutomationFooter()
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Storage")
        .navigationSubtitle(model.lastScan.map { String(localized: "Scanned at \($0.formatted(date: .omitted, time: .shortened))") } ?? "")
        .toolbar {
            ToolbarItem {
                Button("Scan again", systemImage: "arrow.clockwise") { Task { await model.scan() } }
                    .disabled(model.isScanning || model.isCleaning || model.isMovingFiles)
                    .help("Look for things to clean up (⇧⌘R)")
            }
        }
        .task {
            if model.lastScan == nil { await model.scan() }
        }
    }
}

private struct StorageHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let disk = model.disk
        let used = max(0, disk.total - disk.available)
        let reclaim = min(model.selectedBytes, used)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Format.bytes(disk.available)) free")
                        .font(.title.weight(.semibold))
                        .contentTransition(.numericText())
                    Text("of \(Format.capacity(disk.total)) on the startup disk")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.clean() }
                } label: {
                    Label(model.selectedBytes > 0 ? "Clean up \(Format.bytes(model.selectedBytes))" : "Clean up",
                          systemImage: "sparkles")
                        .contentTransition(.numericText())
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.selectedBytes == 0 || model.isCleaning || model.isScanning)
                .keyboardShortcut(.defaultAction)
            }

            GeometryReader { proxy in
                let width = proxy.size.width
                let total = Double(max(disk.total, 1))
                HStack(spacing: 0) {
                    Rectangle().fill(.blue.gradient)
                        .frame(width: width * Double(used - reclaim) / total)
                    Rectangle().fill(.green.gradient)
                        .frame(width: width * Double(reclaim) / total)
                    Rectangle().fill(.quaternary)
                }
                .clipShape(.rect(cornerRadius: 5, style: .continuous))
                .animation(.smooth(duration: 0.5), value: reclaim)
                .animation(.smooth(duration: 0.5), value: disk.available)
            }
            .frame(height: 14)
            .accessibilityElement()
            .accessibilityLabel("Disk")
            .accessibilityValue("\(Format.bytes(used)) used, \(Format.bytes(reclaim)) can be cleaned up, \(Format.bytes(disk.available)) free")

            HStack(spacing: 16) {
                LegendDot(color: .blue, text: String(localized: "Used"))
                LegendDot(color: .green, text: String(localized: "Selected for clean-up: \(Format.bytes(reclaim))"))
                LegendDot(color: .secondary.opacity(0.4), text: String(localized: "Free"))
                Spacer()
                if model.isScanning {
                    ProgressView().controlSize(.small)
                    Text("Scanning…").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(20)
        .background(.background.secondary, in: .rect(cornerRadius: 16, style: .continuous))
    }
}

private struct LegendDot: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

private struct ScanPrompt: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Find out what is taking up space", systemImage: "magnifyingglass")
        } description: {
            Text("MacUnclog looks for caches and build files, and checks that nothing is in use before it deletes anything.")
        } actions: {
            Button("Scan now") { Task { await model.scan() } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}

private struct CleaningProgressView: View {
    let progress: CleanupExecutor.Progress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))) {
                Text("Cleaning up…").font(.headline)
            } currentValueLabel: {
                Text(progress.current).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 12, style: .continuous))
        .transition(.opacity)
    }
}

private struct RunResultBanner: View {
    let run: CleanupRun
    @State private var expanded = false

    private var skipped: [CleanupOutcome] { run.outcomes.filter { $0.result != .removed } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: run.id)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Freed up \(Format.bytes(run.reclaimed))").font(.headline)
                    Text("Free space went from \(Format.bytes(run.freeBefore)) to \(Format.bytes(run.freeAfter)).")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !skipped.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(skipped) { outcome in
                            OutcomeRow(outcome: outcome)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("\(skipped.count) skipped").foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(.green.opacity(0.08), in: .rect(cornerRadius: 12, style: .continuous))
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }
}

struct OutcomeRow: View {
    let outcome: CleanupOutcome

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch outcome.result {
            case .removed:
                Image(systemName: "checkmark").foregroundStyle(.green)
                Text(outcome.title)
                Spacer()
                Text(Format.bytes(outcome.bytes)).foregroundStyle(.secondary).monospacedDigit()
            case .skipped(let reason):
                Image(systemName: "lock").foregroundStyle(.secondary)
                Text(outcome.title)
                Spacer()
                Text(reason).foregroundStyle(.secondary).lineLimit(1)
            case .failed(let reason):
                Image(systemName: "xmark.octagon").foregroundStyle(.red)
                Text(outcome.title)
                Spacer()
                Text(reason).foregroundStyle(.red).lineLimit(2)
            }
        }
        .font(.callout)
    }
}

private struct CategoryList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ordered = CleanupCategory.allCases.filter { !model.state(for: $0).items.isEmpty }
            + CleanupCategory.allCases.filter { model.state(for: $0).items.isEmpty }
        VStack(spacing: 0) {
            ForEach(ordered) { category in
                CategoryRow(category: category)
                if category != ordered.last { Divider().padding(.leading, 82) }
            }
        }
        .background(.background.secondary, in: .rect(cornerRadius: 12, style: .continuous))
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
        .animation(.smooth, value: ordered)
    }
}

private struct CategoryRow: View {
    @Environment(AppModel.self) private var model
    let category: CleanupCategory
    @State private var expanded = false

    var body: some View {
        let state = model.state(for: category)
        let cleanable = state.cleanable
        let total = cleanable.reduce(Int64(0)) { $0 + $1.bytes }
        let selectedCount = cleanable.filter { model.selectedItems.contains($0.id) }.count

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Toggle(isOn: Binding(
                    get: { !cleanable.isEmpty && selectedCount == cleanable.count },
                    set: { on in
                        for item in cleanable {
                            if on { model.selectedItems.insert(item.id) } else { model.selectedItems.remove(item.id) }
                        }
                    }
                )) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(cleanable.isEmpty || model.isCleaning)
                .accessibilityLabel("Select all in \(category.title)")

                Image(systemName: category.symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title).font(.headline)
                    Text(summary(state: state, cleanable: cleanable.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if state.isScanning {
                    ProgressView().controlSize(.small)
                } else if state.items.isEmpty {
                    Text("Nothing").foregroundStyle(.secondary)
                } else {
                    Text(Format.bytes(total))
                        .font(.body.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(total > 0 ? .primary : .secondary)
                        .contentTransition(.numericText())
                }
                Button {
                    withAnimation(.smooth(duration: 0.25)) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 20, height: 20)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .disabled(state.items.isEmpty)
                .opacity(state.items.isEmpty ? 0 : 1)
                .accessibilityLabel(expanded ? "Hide details" : "Show details")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, state.items.isEmpty && state.scanned ? 9 : 12)
            .opacity(state.items.isEmpty && state.scanned ? 0.6 : 1)
            .contentShape(.rect)
            .onTapGesture { if !state.items.isEmpty { withAnimation(.smooth(duration: 0.25)) { expanded.toggle() } } }

            if expanded {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(category.whatIsDeleted)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(state.items) { item in
                        ItemRow(item: item)
                    }
                }
                .padding(14)
                .transition(.opacity)
            }
        }
    }

    private func summary(state: CategoryState, cleanable: Int) -> String {
        if state.isScanning { return String(localized: "Scanning…") }
        if state.items.isEmpty { return state.scanned ? String(localized: "Nothing found") : String(localized: "Not scanned") }
        let blocked = state.items.count - cleanable
        var parts = [String(localized: "\(cleanable) can be cleaned up")]
        if blocked > 0 { parts.append(String(localized: "\(blocked) in use or protected")) }
        return parts.joined(separator: " · ")
    }
}

private struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: CleanupItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if item.isCleanable {
                Toggle(isOn: Binding(
                    get: { model.selectedItems.contains(item.id) },
                    set: { on in if on { model.selectedItems.insert(item.id) } else { model.selectedItems.remove(item.id) } }
                )) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(model.isCleaning)
                .accessibilityLabel(item.title)
            } else {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .accessibilityLabel("Locked")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1).truncationMode(.middle)
                if let reason = item.blocked {
                    Text(reason.description).font(.caption).foregroundStyle(.orange)
                } else if let location = item.location {
                    Text(abbreviate(location)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if let lastUsed = item.lastUsed {
                Text(Format.relative(lastUsed)).font(.caption).foregroundStyle(.secondary)
            }
            Text(Format.bytes(item.bytes))
                .monospacedDigit()
                .foregroundStyle(item.isCleanable ? .primary : .secondary)
                .frame(minWidth: 70, alignment: .trailing)
        }
        .opacity(item.isCleanable ? 1 : 0.7)
        .contextMenu {
            if let location = item.location, location.hasPrefix("/") {
                Button("Show in Finder") { NSWorkspace.shared.selectFile(location, inFileViewerRootedAtPath: "") }
            }
        }
    }

    private func abbreviate(_ path: String) -> String {
        path.hasPrefix(NSHomeDirectory()) ? "~" + path.dropFirst(NSHomeDirectory().count) : path
    }
}

private struct AutomationFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.automationActive ? "clock.badge.checkmark" : "clock")
                .font(.title3)
                .foregroundStyle(model.automationActive ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Automatic clean-up").font(.headline)
                Text(description).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink { Text("Change…") }
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 12, style: .continuous))
    }

    private var description: String {
        let settings = model.settings
        let threshold = settings.lowDiskThresholdGB
        let time = String(format: "%02d:00", settings.hour)
        let schedule = settings.frequency == .daily
            ? String(localized: "daily at \(time)")
            : String(localized: "weekly at \(time)")
        return switch (settings.lowDiskEnabled, settings.scheduleEnabled) {
        case (true, true): String(localized: "Cleans up when free space falls below \(threshold) GB, and \(schedule).")
        case (true, false): String(localized: "Cleans up when free space falls below \(threshold) GB.")
        case (false, true): String(localized: "Cleans up \(schedule).")
        case (false, false): String(localized: "Off. MacUnclog only cleans up when you ask.")
        }
    }
}
