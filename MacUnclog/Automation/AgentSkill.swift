import Foundation

/// The skill in `skills/macunclog`, which tells Claude Code and Codex to check the Mac with
/// MacUnclog before booting a simulator or starting a big build. The app carries a copy and
/// installs it into each agent's skills folder.
enum AgentSkill {
    enum Agent: String, CaseIterable, Identifiable, Sendable {
        case claude, codex

        var id: String { rawValue }

        var title: String {
            switch self {
            case .claude: "Claude Code"
            case .codex: "Codex"
            }
        }

        /// The agent's own folder. Both agents let an environment variable move it.
        var home: URL {
            let environment = ProcessInfo.processInfo.environment
            let home = URL(fileURLWithPath: NSHomeDirectory())
            return switch self {
            case .claude: environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude")
            case .codex: environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
            }
        }

        var skillFile: URL { home.appendingPathComponent("skills/macunclog/SKILL.md") }
    }

    enum Status: Equatable, Sendable {
        /// The agent's folder doesn't exist, so it isn't installed (or has never run).
        case agentMissing
        case notInstalled
        case installed
        /// A different text is installed: an older version, or one someone edited.
        case different
    }

    enum Failure: Error, CustomStringConvertible {
        case notBundled
        case agentMissing(Agent)
        case io(String)

        var description: String {
            switch self {
            case .notBundled: String(localized: "This copy of MacUnclog doesn’t include the skill.")
            case .agentMissing(let agent): String(localized: "\(agent.title) isn’t set up on this Mac.")
            case .io(let message): message
            }
        }
    }

    static let pathLine = "MU=/Applications/MacUnclog.app/Contents/MacOS/MacUnclog"

    /// The bundled skill, pointing at this copy of the app when it isn't in /Applications.
    static func contents(executable: String? = Bundle.main.executablePath) -> String? {
        guard let url = Bundle.main.url(forResource: "macunclog", withExtension: nil)?.appendingPathComponent("SKILL.md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return pointed(text, at: executable)
    }

    static func pointed(_ text: String, at executable: String?) -> String {
        let standard = String(pathLine.dropFirst("MU=".count))
        guard let executable, executable.hasSuffix(".app/Contents/MacOS/MacUnclog"), executable != standard else { return text }
        let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return text.replacingOccurrences(of: pathLine, with: "MU=\(quoted)")
    }

    static func status(of agent: Agent, expected: String? = contents()) -> Status {
        let fm = FileManager.default
        guard fm.fileExists(atPath: agent.home.path) else { return .agentMissing }
        guard let installed = try? String(contentsOf: agent.skillFile, encoding: .utf8) else { return .notInstalled }
        return installed == expected ? .installed : .different
    }

    static func install(for agent: Agent) throws(Failure) {
        guard let text = contents() else { throw .notBundled }
        guard FileManager.default.fileExists(atPath: agent.home.path) else { throw .agentMissing(agent) }
        do {
            try FileManager.default.createDirectory(at: agent.skillFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: agent.skillFile, options: .atomic)
        } catch {
            throw .io(error.localizedDescription)
        }
    }

    /// Removes SKILL.md and, if nothing else is left in it, the skill's folder.
    static func remove(for agent: Agent) throws(Failure) {
        let fm = FileManager.default
        let folder = agent.skillFile.deletingLastPathComponent()
        do {
            if fm.fileExists(atPath: agent.skillFile.path) { try fm.removeItem(at: agent.skillFile) }
            if (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try fm.removeItem(at: folder) }
        } catch {
            throw .io(error.localizedDescription)
        }
    }
}
