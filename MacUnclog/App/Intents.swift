import AppIntents

/// "Why is my Mac slow?" in Shortcuts and Spotlight.
struct DiagnoseMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Why is my Mac slow?"
    static let description = IntentDescription("Measures memory, CPU, disk and temperature, and gives a verdict.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let diagnosis = VerdictEngine.diagnose(await SystemProbe.capture())
        let text = "\(diagnosis.verdict.headline). \(diagnosis.verdict.summary)"
        return .result(value: text, dialog: "\(text)")
    }
}

struct MacUnclogShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DiagnoseMacIntent(),
            phrases: ["Check my Mac with \(.applicationName)", "Ask \(.applicationName) why my Mac is slow"],
            shortTitle: "Why is my Mac slow?",
            systemImageName: "stethoscope"
        )
    }
}
