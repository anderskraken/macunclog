import AppKit
import SwiftUI

/// Sits under the sidebar while a newer release is out.
struct UpdateBanner: View {
    let release: Release

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("MacUnclog \(release.name) is available", systemImage: "arrow.down.circle")
                .fixedSize(horizontal: false, vertical: true)
            Button("Download") { NSWorkspace.shared.open(release.page) }
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 10, style: .continuous))
        .padding(10)
    }
}

/// The Updates section of Settings > General.
struct UpdateSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let updates = model.updates
        Section {
            Toggle("Automatically check for updates", isOn: $model.settings.checkForUpdates)
            if let release = updates.available {
                LabeledContent("MacUnclog \(release.name) is available") {
                    Button("Download") { NSWorkspace.shared.open(release.page) }
                }
            }
            LabeledContent("Last checked") {
                HStack(spacing: 8) {
                    if updates.isChecking {
                        ProgressView().controlSize(.small)
                    } else if let failure = updates.failure {
                        Text("Couldn’t check").help(failure)
                    } else {
                        Text(updates.lastCheck.map { Format.relative($0) } ?? String(localized: "Never"))
                    }
                    Button("Check now") { Task { await updates.check() } }
                        .disabled(updates.isChecking)
                }
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("MacUnclog asks GitHub once a day for the newest version. It never downloads or installs anything by itself.")
                .foregroundStyle(.secondary)
        }
    }
}

/// The answer to Check for Updates… in the app menu. An alert, because the main window
/// may be closed while the app runs in the menu bar.
@MainActor
enum UpdateAlert {
    static func show(_ outcome: UpdateChecker.Outcome) {
        let alert = NSAlert()
        switch outcome {
        case .available(let release):
            alert.messageText = String(localized: "MacUnclog \(release.name) is available")
            alert.informativeText = String(localized: "You have version \(AppVersion.running?.description ?? ""). Download the new version from GitHub and replace the app in Applications.")
            alert.addButton(withTitle: String(localized: "Download"))
            alert.addButton(withTitle: String(localized: "Later"))
        case .upToDate:
            alert.messageText = String(localized: "MacUnclog is up to date")
            alert.informativeText = String(localized: "Version \(AppVersion.running?.description ?? "") is the newest.")
        case .failed(let reason):
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Couldn’t check for updates")
            alert.informativeText = reason
        }
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn, case .available(let release) = outcome {
            NSWorkspace.shared.open(release.page)
        }
    }
}
