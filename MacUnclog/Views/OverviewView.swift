import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let diagnosis = model.diagnosis {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VerdictCard(diagnosis: diagnosis)
                        MetricsGrid(snapshot: diagnosis.snapshot)
                        // The first serious finding is already the verdict card's text and buttons.
                        FindingsSection(findings: diagnosis.findings.filter { $0.id != VerdictCard.primary(of: diagnosis)?.id })
                    }
                    .padding(24)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            } else {
                ProgressView("Measuring memory, CPU and disk…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Overview")
        .navigationSubtitle(model.diagnosis.map { String(localized: "Measured at \($0.snapshot.takenAt.formatted(date: .omitted, time: .shortened))") } ?? "")
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refreshDiagnosis() }
                }
                .disabled(model.isDiagnosing)
                .help("Measure again (⌘R)")
            }
        }
    }
}

private struct VerdictCard: View {
    let diagnosis: Diagnosis

    private var verdict: Verdict { diagnosis.verdict }
    static func primary(of diagnosis: Diagnosis) -> Finding? { diagnosis.findings.first { $0.severity >= .warning } }
    private var primary: Finding? { Self.primary(of: diagnosis) }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: verdict.severity.verdictSymbol)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(verdict.severity.tint.gradient)
                .symbolEffect(.bounce, value: verdict.severity)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 56)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(verdict.headline)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                Text(verdict.summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let primary {
                    RemedyButtons(remedies: primary.remedies)
                        .padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(.background.secondary, in: .rect(cornerRadius: 16, style: .continuous))
        // The summary carries live figures; only a new headline is worth animating.
        .animation(.smooth, value: verdict.headline)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(verdict.headline). \(verdict.summary)")
    }
}

private struct MetricsGrid: View {
    @Environment(AppModel.self) private var model
    let snapshot: SystemSnapshot
    private var threshold: Int64 { model.settings.lowDiskThreshold }
    @State private var width: CGFloat = 900

    var body: some View {
        let wide = width >= 660
        let columns = Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: wide ? 4 : 2)
        LazyVGrid(columns: columns, spacing: 14) {
            let memory = snapshot.memory
            MetricTile(
                stacked: wide, title: String(localized: "Memory"), symbol: "memorychip",
                value: String(localized: "\(Format.memory(memory.used)) of \(Format.memory(memory.total))"),
                detail: String(localized: "\(pressureLabel(memory.pressure)) · swap \(Format.memory(memory.swapUsed))"),
                fraction: memory.usedFraction,
                severity: memory.severity
            )
            MetricTile(
                stacked: wide, title: String(localized: "CPU"), symbol: "cpu",
                value: Format.percent(snapshot.cpu.usage * 100),
                detail: String(localized: "of \(snapshot.cpu.cores) cores"),
                fraction: snapshot.cpu.usage,
                severity: snapshot.cpu.severity
            )
            .help("Load average, last minute: \(snapshot.cpu.load1.formatted(.number.precision(.fractionLength(1))))")
            MetricTile(
                stacked: wide, title: String(localized: "Disk"), symbol: "internaldrive",
                value: String(localized: "\(Format.bytes(snapshot.disk.available)) free"),
                detail: String(localized: "of \(Format.capacity(snapshot.disk.total))"),
                fraction: snapshot.disk.usedFraction,
                severity: snapshot.disk.severity(threshold: threshold)
            )
            MetricTile(
                stacked: wide, title: String(localized: "Temperature"), symbol: snapshot.thermal >= .serious ? "thermometer.high" : "thermometer.medium",
                value: snapshot.thermal.label,
                detail: thermalDetail(snapshot),
                fraction: nil,
                severity: snapshot.thermal.severity,
                tint: snapshot.thermal == .fair ? .yellow : nil
            )
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
    }

    private func pressureLabel(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: String(localized: "Normal pressure")
        case .warning: String(localized: "High pressure")
        case .critical: String(localized: "Critical pressure")
        }
    }

    private func thermalDetail(_ snapshot: SystemSnapshot) -> String {
        let base = switch snapshot.thermal {
        case .nominal: String(localized: "No throttling")
        case .fair: String(localized: "Fans working harder")
        case .serious: String(localized: "CPU throttled")
        case .critical: String(localized: "Heavily throttled")
        }
        return snapshot.power.lowPowerMode ? base + " · " + String(localized: "Low Power Mode") : base
    }
}

private struct MetricTile: View {
    let stacked: Bool
    let title: String
    let symbol: String
    let value: String
    let detail: String
    let fraction: Double?
    let severity: Severity
    /// Overrides the severity colour, for states that aren't a problem but aren't calm either.
    var tint: Color? = nil

    private var color: Color { tint ?? severity.tint }

    var body: some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 14))
        layout {
            ZStack {
                if let fraction {
                    RingMeter(fraction: fraction, tint: color)
                } else {
                    Circle().fill(color.opacity(0.15))
                }
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(color)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text(value)
                    .font(.headline)
                    .lineLimit(2)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value). \(detail). \(severity.label)")
    }
}

private struct FindingsSection: View {
    let findings: [Finding]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Findings").font(.headline)
            if findings.isEmpty {
                Label("Nothing to report. Memory, CPU, disk and temperature are within normal range.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(findings) { finding in
                        FindingRow(finding: finding)
                        if finding.id != findings.last?.id { Divider().padding(.leading, 52) }
                    }
                }
                .background(.background.secondary, in: .rect(cornerRadius: 12, style: .continuous))
            }
        }
        .animation(.smooth, value: findings.map(\.id))
    }
}

private struct FindingRow: View {
    let finding: Finding

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: finding.symbol)
                .font(.title3)
                .foregroundStyle(finding.severity.tint)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(finding.title).font(.body.weight(.semibold))
                    Text(finding.severity.label)
                        .font(.caption)
                        .foregroundStyle(finding.severity.tint)
                }
                Text(finding.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !finding.remedies.isEmpty {
                    RemedyButtons(remedies: finding.remedies, controlSize: .small)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
