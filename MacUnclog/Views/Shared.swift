import AppKit
import SwiftUI

extension Severity {
    var tint: Color {
        switch self {
        case .good: .green
        case .notice: .blue
        case .warning: .orange
        case .critical: .red
        }
    }

    var verdictSymbol: String {
        switch self {
        case .good: "checkmark.seal.fill"
        case .notice: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"
        }
    }

    var label: String {
        switch self {
        case .good: String(localized: "Good")
        case .notice: String(localized: "Worth a look")
        case .warning: String(localized: "Slowing your Mac down")
        case .critical: String(localized: "Serious")
        }
    }
}

extension ThermalLevel {
    var label: String {
        switch self {
        case .nominal: String(localized: "Normal")
        case .fair: String(localized: "Warm")
        case .serious: String(localized: "Throttled")
        case .critical: String(localized: "Critical")
        }
    }

    var severity: Severity {
        switch self {
        case .nominal: .good
        case .fair: .notice
        case .serious: .warning
        case .critical: .critical
        }
    }
}

/// A ring meter in the style of the Battery and Storage panes.
struct RingMeter: View {
    let fraction: Double
    let tint: Color
    var lineWidth: CGFloat = 7

    /// Whole percents, so a refresh that changes nothing visible doesn't redraw the ring.
    private var shown: Double { (max(0.001, min(1, fraction)) * 100).rounded() / 100 }

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: shown)
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        // Animating every small change redraws the gradient frame by frame on the CPU;
        // only steps of five points are worth the motion.
        .animation(.smooth(duration: 0.6), value: Int(shown * 20))
        .accessibilityHidden(true)
    }
}

struct AppIconView: View {
    let pid: pid_t
    var bundleIdentifier: String?
    var executablePath: String?
    var size: CGFloat = 18

    private var bundleURL: URL? {
        NSRunningApplication(processIdentifier: pid)?.bundleURL
            ?? bundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    /// ".../Simulator.app/Contents/MacOS/Simulator" belongs to Simulator.app.
    private var executableBundle: URL? {
        guard let path = executablePath, let range = path.range(of: ".app/Contents/MacOS/", options: .backwards) else { return nil }
        return URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app")
    }

    var body: some View {
        Group {
            if let url = bundleURL ?? executableBundle {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: "gearshape").resizable().scaledToFit().padding(size * 0.15).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct RemedyButtons: View {
    @Environment(AppModel.self) private var model
    let remedies: [Remedy]
    var controlSize: ControlSize = .regular

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(remedies.enumerated()), id: \.offset) { index, remedy in
                let button = Button(title(remedy), systemImage: symbol(remedy)) { model.perform(remedy) }
                    .controlSize(controlSize)
                if index == 0 {
                    button.buttonStyle(.borderedProminent)
                } else {
                    button.buttonStyle(.bordered)
                }
            }
        }
    }

    private func title(_ remedy: Remedy) -> String {
        switch remedy {
        case .quit(let ref): String(localized: "Quit \(ref.name)")
        case .forceQuit(let ref): String(localized: "Force quit \(ref.name)")
        case .resume(let ref): String(localized: "Resume \(ref.name)")
        case .freeDisk: String(localized: "Free up space")
        case .openBatterySettings: String(localized: "Battery settings")
        case .shutDownIdleSimulators(let count):
            count == 1 ? String(localized: "Shut down the idle simulator") : String(localized: "Shut down \(count) idle simulators")
        case .stopOrphanedTools(let count):
            count == 1 ? String(localized: "Stop the tool") : String(localized: "Stop \(count) tools")
        case .showAgents: String(localized: "Show agents")
        }
    }

    private func symbol(_ remedy: Remedy) -> String {
        switch remedy {
        case .quit: "xmark.circle"
        case .forceQuit: "xmark.octagon"
        case .resume: "play.circle"
        case .freeDisk: "sparkles"
        case .openBatterySettings: "battery.75percent"
        case .shutDownIdleSimulators: "power"
        case .stopOrphanedTools: "stop.circle"
        case .showAgents: "person.2.wave.2"
        }
    }
}
