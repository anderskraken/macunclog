import SwiftUI

struct MacUnclogApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("MacUnclog", id: "main") {
            MainView()
                .environment(model)
                .task { model.startAutoRefresh() }
                .onAppear { model.setVisible(true) }
                .onDisappear { model.setVisible(false) }
        }
        .defaultSize(width: 960, height: 680)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh diagnosis") { Task { await model.refreshDiagnosis() } }
                    .keyboardShortcut("r")
                Button("Scan for things to clean up") {
                    model.selection = .disk
                    Task { await model.scan() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
                .task { model.startAutoRefresh() }
                .onAppear { model.setVisible(true) }
                .onDisappear { model.setVisible(false) }
        } label: {
            MenuBarLabel(severity: model.diagnosis?.verdict.severity ?? .good)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }

        #if DEBUG
        // `-MUOpen menubar` shows the menu bar panel in a window, for screenshots.
        Window("Menu bar", id: "menubar-preview") {
            MenuBarView()
                .environment(model)
                .background(.regularMaterial, in: .rect(cornerRadius: 14, style: .continuous))
                .padding(1)
                .task { model.startAutoRefresh() }
                .onAppear { model.setVisible(true) }
                .onDisappear { model.setVisible(false) }
        }
        .windowResizability(.contentSize)
        .windowStyle(.plain)
        .restorationBehavior(.disabled)
        #endif
    }
}

struct MenuBarLabel: View {
    let severity: Severity

    var body: some View {
        Image(systemName: severity >= .warning ? "gauge.with.dots.needle.67percent" : "gauge.with.dots.needle.33percent")
            .accessibilityLabel(severity >= .warning ? "MacUnclog: Your Mac is slow" : "MacUnclog")
    }
}
