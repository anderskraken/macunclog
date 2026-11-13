import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $model.selection) { item in
                Label(item.title, systemImage: item.symbol)
                    .badge(badge(for: item))
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            switch model.selection ?? .overview {
            case .overview: OverviewView()
            case .agents: AgentsView()
            case .processes: ProcessesView()
            case .disk: DiskView()
            case .history: HistoryView()
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .task {
            #if DEBUG
            if DemoData.isEnabled { NSApp.activate() }
            #endif
            switch UserDefaults.standard.string(forKey: "MUOpen") {
            case "settings": openSettings()
            case "menubar": openWindow(id: "menubar-preview")
            default: break
            }
        }
        .confirmationDialog(
            model.pendingToolStop?.count == 1 ? "Stop this tool?" : "Stop \(model.pendingToolStop?.count ?? 0) tools?",
            isPresented: Binding(get: { model.pendingToolStop != nil }, set: { if !$0 { model.pendingToolStop = nil } }),
            presenting: model.pendingToolStop
        ) { tools in
            Button(tools.count == 1 ? "Stop" : "Stop all", role: .destructive) {
                Task { await model.confirmStop(tools) }
            }
        } message: { tools in
            Text(tools.map { tool in
                [tool.label, tool.place?.title, "PID \(tool.pid)"].compactMap { $0 }.joined(separator: " · ")
            }.joined(separator: "\n"))
        }
        .alert("That didn’t work", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
    }

    private func badge(for item: SidebarItem) -> Text? {
        switch item {
        case .overview:
            let count = model.diagnosis?.findings.filter { $0.severity >= .warning }.count ?? 0
            return count > 0 ? Text("\(count)") : nil
        case .agents:
            let agents = model.diagnosis?.snapshot.agents
            let attention = (agents?.idleSimulators.count ?? 0) + (agents?.stoppableTools.count ?? 0)
            return attention > 0 ? Text("\(attention)") : nil
        case .disk:
            return model.reclaimableBytes > 0 ? Text(Format.bytes(model.reclaimableBytes)) : nil
        default:
            return nil
        }
    }
}
