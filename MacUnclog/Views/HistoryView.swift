import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.history.isEmpty {
                ContentUnavailableView("No clean-ups yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("This is where you’ll see what MacUnclog has deleted, whether you cleaned up yourself or it happened automatically."))
            } else {
                List(model.history) { run in
                    RunRow(run: run)
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
            }
        }
        .navigationTitle("History")
        .onAppear { model.reloadHistory() }
        .toolbar {
            ToolbarItem {
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.open(HistoryStore.folder)
                }
                .help("Open the folder with the log files")
            }
        }
    }
}

private struct RunRow: View {
    let run: CleanupRun
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(run.outcomes) { OutcomeRow(outcome: $0) }
                ForEach(run.repositories ?? []) { RepoRecordRow(record: $0) }
            }
            .padding(.vertical, 6)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    if let repositories = run.repositories {
                        let moved = repositories.filter { $0.result == .removed }
                        Text("Repositories moved to the Bin · \(Format.bytes(moved.reduce(Int64(0)) { $0 + $1.bytes }))").font(.headline)
                        Text("\(run.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(moved.count) of \(repositories.count) moved")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(trigger) · freed up \(Format.bytes(run.reclaimed))").font(.headline)
                        Text("\(run.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(run.removedCount) of \(run.outcomes.count) cleaned up · free \(Format.bytes(run.freeBefore)) → \(Format.bytes(run.freeAfter))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var trigger: String {
        switch run.trigger {
        case .manual: String(localized: "Manual clean-up")
        case .schedule: String(localized: "Scheduled clean-up")
        case .lowDisk: String(localized: "Low disk space")
        }
    }

    private var symbol: String {
        if run.repositories != nil { return "arrow.triangle.branch" }
        return switch run.trigger {
        case .manual: "hand.tap"
        case .schedule: "calendar"
        case .lowDisk: "internaldrive.fill"
        }
    }
}
