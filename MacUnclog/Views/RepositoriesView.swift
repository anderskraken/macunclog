import SwiftUI

/// Git repositories whose whole content is on GitHub. Nothing is selected until the user
/// ticks it, the only action is moving to the Bin, and History can clone it back.
struct RepositoriesSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false
    @State private var expanded = false

    var body: some View {
        let movable = model.repositories.filter(\.canMove)
        let kept = model.repositories.filter { !$0.canMove }
        let selected = movable.filter { model.selectedRepos.contains($0.id) }
        let selectedBytes = selected.reduce(Int64(0)) { $0 + $1.bytes }

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Repositories fully on GitHub").font(.title3.weight(.semibold))
                Spacer()
                Button("Move to Bin…", systemImage: "trash") { confirming = true }
                    .disabled(selected.isEmpty || model.isMovingRepos || model.isScanning)
                    .help("Move the selected repositories to the Bin")
            }
            if let records = model.lastRepoMove {
                RepoMoveBanner(records: records)
            }
            VStack(alignment: .leading, spacing: 0) {
                header(movable: movable, kept: kept.count, selectedCount: selected.count)
                if expanded && !model.repositories.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(movable) { RepoRow(repo: $0) }
                        if !kept.isEmpty {
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(kept) { RepoRow(repo: $0) }
                                }
                                .padding(.top, 8)
                            } label: {
                                Text(kept.count == 1 ? "1 repository stays" : "\(kept.count) repositories stay")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(14)
                    .transition(.opacity)
                }
            }
            .background(.background.secondary, in: .rect(cornerRadius: 12, style: .continuous))
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
        }
        .confirmationDialog(
            selected.count == 1
                ? String(localized: "Move “\(selected.first?.name ?? "")” to the Bin?")
                : String(localized: "Move \(selected.count) repositories to the Bin?"),
            isPresented: $confirming
        ) {
            Button("Move to Bin") { Task { await model.moveSelectedReposToBin() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if selected.count == 1 {
                Text("It takes up \(Format.bytes(selectedBytes)). MacUnclog checks it again first. You can put it back from the Bin, or clone it again from History.")
            } else {
                Text("They take up \(Format.bytes(selectedBytes)). MacUnclog checks each one again first. You can put them back from the Bin, or clone them again from History.")
            }
        }
    }

    private func header(movable: [LocalRepo], kept: Int, selectedCount: Int) -> some View {
        let total = movable.reduce(Int64(0)) { $0 + $1.bytes }
        let empty = model.repositories.isEmpty
        return HStack(spacing: 12) {
            Toggle(isOn: Binding(
                get: { !movable.isEmpty && selectedCount == movable.count },
                set: { on in
                    for repo in movable {
                        if on { model.selectedRepos.insert(repo.id) } else { model.selectedRepos.remove(repo.id) }
                    }
                }
            )) { EmptyView() }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(movable.isEmpty || model.isMovingRepos)
            .accessibilityLabel("Select all repositories")

            Image(systemName: "arrow.triangle.branch")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Repositories").font(.headline)
                Text(summary(movable: movable.count, kept: kept))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isFindingRepos {
                ProgressView().controlSize(.small)
            } else if movable.isEmpty {
                Text("Nothing").foregroundStyle(.secondary)
            } else {
                Text(Format.bytes(total))
                    .font(.body.weight(.medium))
                    .monospacedDigit()
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
            .disabled(empty)
            .opacity(empty ? 0 : 1)
            .accessibilityLabel(expanded ? "Hide details" : "Show details")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, empty ? 9 : 12)
        .opacity(empty && !model.isFindingRepos ? 0.6 : 1)
        .contentShape(.rect)
        .onTapGesture { if !empty { withAnimation(.smooth(duration: 0.25)) { expanded.toggle() } } }
    }

    private func summary(movable: Int, kept: Int) -> String {
        if model.isFindingRepos { return String(localized: "Checking each repository against GitHub…") }
        if model.repositories.isEmpty { return model.lastScan == nil ? String(localized: "Not scanned") : String(localized: "No repositories found") }
        var parts = [movable == 1 ? String(localized: "1 can go") : String(localized: "\(movable) can go")]
        if kept > 0 { parts.append(kept == 1 ? String(localized: "1 stays") : String(localized: "\(kept) stay")) }
        return parts.joined(separator: " · ")
    }
}

private struct RepoRow: View {
    @Environment(AppModel.self) private var model
    let repo: LocalRepo

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if repo.canMove {
                Toggle(isOn: Binding(
                    get: { model.selectedRepos.contains(repo.id) },
                    set: { on in if on { model.selectedRepos.insert(repo.id) } else { model.selectedRepos.remove(repo.id) } }
                )) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(model.isMovingRepos)
                .accessibilityLabel(repo.name)
            } else {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .accessibilityLabel("Stays")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name).lineLimit(1).truncationMode(.middle)
                if let reason = repo.blocked {
                    Text(reason.description).font(.caption).foregroundStyle(.orange)
                        .lineLimit(2).truncationMode(.tail)
                } else {
                    Text(details).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if let date = repo.lastActivity {
                Text(Format.relative(date)).font(.caption).foregroundStyle(.secondary)
                    .help("Last commit")
            }
            if repo.canMove {
                Text(Format.bytes(repo.bytes))
                    .monospacedDigit()
                    .frame(minWidth: 70, alignment: .trailing)
            }
        }
        .opacity(repo.canMove ? 1 : 0.7)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.selectFile(repo.path, inFileViewerRootedAtPath: "") }
            if let url = repo.remote?.webURL {
                Button("Open on GitHub") { NSWorkspace.shared.open(url) }
            }
        }
    }

    private var details: String {
        guard let remote = repo.remote else { return repo.folder }
        return "\(remote.slug) · \(repo.folder)"
    }
}

private struct RepoMoveBanner: View {
    let records: [RepoRecord]

    var body: some View {
        let moved = records.filter { $0.result == .removed }
        let bytes = moved.reduce(Int64(0)) { $0 + $1.bytes }
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: moved.count == records.count ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(moved.count == records.count ? .green : .orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                if !moved.isEmpty {
                    Text(moved.count == 1
                         ? "Moved 1 repository to the Bin. Empty the Bin to free up to \(Format.bytes(bytes))."
                         : "Moved \(moved.count) repositories to the Bin. Empty the Bin to free up to \(Format.bytes(bytes)).")
                }
                ForEach(records.filter { $0.result != .removed }) { record in
                    Text("Kept \(record.name): \(record.result.reason)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !moved.isEmpty {
                Button("Open Bin") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash"))
                }
            }
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 10, style: .continuous))
    }
}

/// A repository in a History entry, with a button that clones it back to where it was.
struct RepoRecordRow: View {
    @Environment(AppModel.self) private var model
    let record: RepoRecord

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch record.result {
            case .removed: Image(systemName: "trash").foregroundStyle(.secondary)
            case .skipped: Image(systemName: "lock").foregroundStyle(.secondary)
            case .failed: Image(systemName: "xmark.octagon").foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                Text(record.result == .removed ? origin : record.result.reason)
                    .font(.caption)
                    .foregroundStyle(record.result.isFailure ? .red : .secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
            if record.result == .removed {
                if model.cloning.contains(record.id) {
                    ProgressView().controlSize(.small)
                } else if FileManager.default.fileExists(atPath: record.path) {
                    Text("In place").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Clone again") { Task { await model.cloneAgain(record) } }
                        .help(record.slug.map { String(localized: "Runs gh repo clone \($0) at its old place") }
                              ?? String(localized: "Runs git clone at its old place"))
                }
            }
        }
        .font(.callout)
    }

    private var origin: String {
        let place = Repositories.abbreviate(record.path)
        guard let slug = record.slug else { return "\(record.remoteURL) → \(place)" }
        return "\(slug) → \(place)"
    }
}

extension CleanupOutcome.Result {
    var reason: String {
        switch self {
        case .removed: ""
        case .skipped(let reason), .failed(let reason): reason
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
