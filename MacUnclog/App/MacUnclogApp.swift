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
                .background(OcclusionReader { covered in model.setCovered(covered) })
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
        // A template image, so macOS tints it for the menu bar. The cup fills in when the Mac is slow.
        Image(severity >= .warning ? "MenuBarPlungerFilled" : "MenuBarPlunger")
            .accessibilityLabel(severity >= .warning ? "MacUnclog: Your Mac is slow" : "MacUnclog")
    }
}

/// Reports when the window it sits in becomes fully covered by other windows or
/// visible again, so the app can refresh less while nobody can see it.
struct OcclusionReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView { Probe(onChange: onChange) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Probe: NSView {
        let onChange: (Bool) -> Void
        private var covered = false
        private var observer: NSObjectProtocol?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if covered {
                covered = false
                onChange(false)
            }
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
            // A window that starts hidden never changes state, so read it now as well.
            DispatchQueue.main.async { [weak self] in self?.update() }
        }

        private func update() {
            guard let window else { return }
            let nowCovered = !window.occlusionState.contains(.visible)
            guard nowCovered != covered else { return }
            covered = nowCovered
            onChange(nowCovered)
        }
    }
}
