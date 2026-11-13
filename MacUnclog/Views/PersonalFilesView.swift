import SwiftUI
import UniformTypeIdentifiers

/// Installers and large files in the user's own folders. Nothing is selected until the
/// user ticks it, and the only action is moving to the Bin.
struct PersonalFilesSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false

    var body: some View {
        let selected = model.personalFiles.filter { model.selectedFiles.contains($0.id) && $0.canMove }
        let selectedBytes = selected.reduce(Int64(0)) { $0 + $1.bytes }

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your files").font(.title3.weight(.semibold))
                Spacer()
                Button("Move to Bin…", systemImage: "trash") { confirming = true }
                    .disabled(selected.isEmpty || model.isMovingFiles || model.isScanning)
                    .help("Move the selected files to the Bin")
            }
            if let move = model.lastBinMove {
                BinMoveBanner(move: move)
            }
            VStack(spacing: 0) {
                PersonalFileGroup(kind: .installer)
                Divider().padding(.leading, 82)
                PersonalFileGroup(kind: .large)
            }
            .background(.background.secondary, in: .rect(cornerRadius: 12, style: .continuous))
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
        }
        .confirmationDialog(
            selected.count == 1
                ? String(localized: "Move “\(selected.first?.name ?? "")” to the Bin?")
                : String(localized: "Move \(selected.count) files to the Bin?"),
            isPresented: $confirming
        ) {
            Button("Move to Bin") { Task { await model.moveSelectedFilesToBin() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if selected.count == 1 {
                Text("It takes up \(Format.bytes(selectedBytes)). You can put it back from the Bin until you empty it.")
            } else {
                Text("They take up \(Format.bytes(selectedBytes)). You can put them back from the Bin until you empty it.")
            }
        }
    }
}

private struct BinMoveBanner: View {
    let move: BinMove

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: move.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(move.failed.isEmpty ? .green : .orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                if !move.moved.isEmpty {
                    Text(move.moved.count == 1
                         ? "Moved 1 file to the Bin. Empty the Bin to free up to \(Format.bytes(move.bytes))."
                         : "Moved \(move.moved.count) files to the Bin. Empty the Bin to free up to \(Format.bytes(move.bytes)).")
                }
                ForEach(move.failed, id: \.self) { failure in
                    Text("Couldn’t move \(failure.file.name): \(failure.reason)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !move.moved.isEmpty {
                Button("Open Bin") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash"))
                }
            }
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 10, style: .continuous))
    }
}

private struct PersonalFileGroup: View {
    @Environment(AppModel.self) private var model
    let kind: PersonalFile.Kind
    @State private var expanded = false

    var body: some View {
        let files = model.personalFiles.filter { $0.kind == kind }
        let movable = files.filter(\.canMove)
        let total = movable.reduce(Int64(0)) { $0 + $1.bytes }
        let selectedCount = movable.filter { model.selectedFiles.contains($0.id) }.count

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Toggle(isOn: Binding(
                    get: { !movable.isEmpty && selectedCount == movable.count },
                    set: { on in
                        for file in movable {
                            if on { model.selectedFiles.insert(file.id) } else { model.selectedFiles.remove(file.id) }
                        }
                    }
                )) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(movable.isEmpty || model.isMovingFiles)
                .accessibilityLabel("Select all in \(kind.title)")

                Image(systemName: kind.symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title).font(.headline)
                    Text(summary(files: files, movable: movable.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isFindingFiles {
                    ProgressView().controlSize(.small)
                } else if files.isEmpty {
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
                .disabled(files.isEmpty)
                .opacity(files.isEmpty ? 0 : 1)
                .accessibilityLabel(expanded ? "Hide details" : "Show details")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, files.isEmpty ? 9 : 12)
            .opacity(files.isEmpty && !model.isFindingFiles ? 0.6 : 1)
            .contentShape(.rect)
            .onTapGesture { if !files.isEmpty { withAnimation(.smooth(duration: 0.25)) { expanded.toggle() } } }

            if expanded && !files.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(files) { file in
                        PersonalFileRow(file: file)
                    }
                }
                .padding(14)
                .transition(.opacity)
            }
        }
    }

    private func summary(files: [PersonalFile], movable: Int) -> String {
        if model.isFindingFiles { return String(localized: "Looking…") }
        if files.isEmpty { return model.lastScan == nil ? String(localized: "Not scanned") : String(localized: "Nothing found") }
        var parts = [movable == 1 ? String(localized: "1 file") : String(localized: "\(movable) files")]
        let open = files.count - movable
        if open > 0 { parts.append(String(localized: "\(open) in use")) }
        return parts.joined(separator: " · ")
    }
}

private struct PersonalFileRow: View {
    @Environment(AppModel.self) private var model
    let file: PersonalFile

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if file.canMove {
                Toggle(isOn: Binding(
                    get: { model.selectedFiles.contains(file.id) },
                    set: { on in if on { model.selectedFiles.insert(file.id) } else { model.selectedFiles.remove(file.id) } }
                )) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(model.isMovingFiles)
                .accessibilityLabel(file.name)
            } else {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .accessibilityLabel("Locked")
            }
            FileIcon(path: file.path)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).lineLimit(1).truncationMode(.middle)
                if let reason = file.blocked {
                    Text(reason.description).font(.caption).foregroundStyle(.orange)
                } else {
                    Text(file.folder).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if let modified = file.modified {
                Text(Format.relative(modified)).font(.caption).foregroundStyle(.secondary)
            }
            Text(Format.bytes(file.bytes))
                .monospacedDigit()
                .foregroundStyle(file.canMove ? .primary : .secondary)
                .frame(minWidth: 70, alignment: .trailing)
        }
        .opacity(file.canMove ? 1 : 0.7)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "") }
        }
    }
}

private struct FileIcon: View {
    let path: String

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
    }

    private var icon: NSImage {
        if FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }
        let type = UTType(filenameExtension: (path as NSString).pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}

extension PersonalFile.Kind {
    var title: String {
        switch self {
        case .installer: String(localized: "Installers")
        case .large: String(localized: "Large files")
        }
    }

    var symbol: String {
        switch self {
        case .installer: "shippingbox"
        case .large: "doc"
        }
    }
}
