import Foundation

/// What coding agents have running on the Mac: their sessions, the simulators they boot,
/// and the dev servers and builds they start. Built from the process tree, so every tool
/// is tied to the session that started it, or marked orphaned when that session is gone.
struct AgentLoad: Sendable {
    var sessions: [AgentSession] = []
    var simulators: [BootedSimulator] = []
    var tools: [ToolProcess] = []

    static let empty = AgentLoad()

    var stoppableTools: [ToolProcess] { tools.filter(\.isStoppable) }
    var idleSimulators: [BootedSimulator] { simulators.filter { $0.idleReason != nil } }
    var simulatorMemory: UInt64 { simulators.reduce(0) { $0 + $1.memoryBytes } }
}

enum AgentKind: String, Sendable, Hashable {
    case claude = "Claude"
    case codex = "Codex"
}

struct AgentSession: Identifiable, Sendable, Hashable {
    let pid: pid_t
    let kind: AgentKind
    let folder: String?
    let startedAt: Date
    /// The session process and everything it started, simulators excluded.
    let processCount: Int
    let cpuPercent: Double
    let memoryBytes: UInt64

    var id: pid_t { pid }
    var place: ProjectPlace? { folder.flatMap { $0 == "/" ? nil : ProjectPlace(path: $0) } }
}

struct BootedSimulator: Identifiable, Sendable, Hashable {
    let udid: String
    let name: String
    let runtime: String
    let bootedAt: Date
    let cpuPercent: Double
    let memoryBytes: UInt64
    /// Processes outside the simulator that name its UDID (xcodebuild -destination, simctl).
    let users: [ProcessRef]
    /// Set when nothing seems to use the simulator: booted a while ago, quiet, unreferenced.
    let idleReason: String?

    var id: String { udid }
}

enum ToolOwner: Sendable, Hashable {
    case session(pid_t, AgentKind)
    case terminal
    /// Started by an agent session (its environment says so) that no longer exists.
    case orphaned
    /// Neither a live session, a terminal nor a finished agent session: an IDE, a service
    /// manager, a LaunchAgent. MacUnclog can't tell who needs it, so it leaves it alone.
    case unknown
}

/// What a tool's environment says about the agent session that started it.
/// Claude Code sets CLAUDECODE=1 and CLAUDE_PID; Codex sets CODEX_* variables.
struct AgentLaunch: Sendable, Hashable {
    let kind: AgentKind
    let sessionPID: pid_t?

    static func parse(environment: [String]) -> AgentLaunch? {
        var claude = false, codex = false
        var sessionPID: pid_t?
        for entry in environment {
            if entry == "CLAUDECODE=1" || entry.hasPrefix("CLAUDE_CODE_SESSION_ID=") { claude = true }
            if entry.hasPrefix("CLAUDE_PID=") { sessionPID = pid_t(entry.dropFirst("CLAUDE_PID=".count)) }
            if entry.hasPrefix("CODEX_SANDBOX") || entry.hasPrefix("CODEX_THREAD_ID=") || entry.hasPrefix("CODEX_MANAGED_BY") { codex = true }
        }
        if claude { return AgentLaunch(kind: .claude, sessionPID: sessionPID) }
        if codex { return AgentLaunch(kind: .codex, sessionPID: nil) }
        return nil
    }
}

enum ToolKind: String, Sendable, Hashable {
    case devServer, emulator, build, watcher, daemon

    var title: String {
        switch self {
        case .devServer: String(localized: "Dev server")
        case .emulator: String(localized: "Emulator")
        case .build: String(localized: "Build")
        case .watcher: String(localized: "Watcher")
        case .daemon: String(localized: "Daemon")
        }
    }
}

struct ToolProcess: Identifiable, Sendable, Hashable {
    let pid: pid_t
    let kind: ToolKind
    let label: String
    let folder: String?
    let ports: [Int]
    let owner: ToolOwner
    let startedAt: Date
    /// The tool and its children, which a stop also ends.
    let processIDs: [pid_t]
    let cpuPercent: Double
    let memoryBytes: UInt64

    var id: pid_t { pid }
    var place: ProjectPlace? { folder.map(ProjectPlace.init(path:)) }

    /// Only a tool whose session is gone, and a shared daemon that is idle, may be stopped.
    var isStoppable: Bool { owner == .orphaned && !(kind == .daemon && cpuPercent >= 5) }
}

/// "weather-app › radar-map" for a Claude worktree, the folder name otherwise.
struct ProjectPlace: Sendable, Hashable {
    let path: String

    var title: String {
        let parts = path.components(separatedBy: "/.claude/worktrees/")
        if parts.count == 2 {
            let repo = URL(fileURLWithPath: parts[0]).lastPathComponent
            let worktree = parts[1].split(separator: "/").first.map(String.init) ?? parts[1]
            return "\(repo) › \(worktree)"
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    var isWorktree: Bool { path.contains("/.claude/worktrees/") }
}

extension String {
    /// Plain byte search. Called about 100,000 times per measurement, where Foundation's
    /// `contains` showed up as most of the app's CPU time.
    func containsBytes(_ needle: String) -> Bool {
        var haystack = self
        var needle = needle
        return haystack.withUTF8 { hay in
            needle.withUTF8 { pin in
                pin.isEmpty || memmem(hay.baseAddress, hay.count, pin.baseAddress, pin.count) != nil
            }
        }
    }
}

/// One row of `ps -A -o pid=,ppid=,etime=,command=`. The name and both signatures are
/// worked out once here, since the tree walks ask for them thousands of times.
struct ProcessRow: Sendable, Hashable {
    let pid: pid_t
    let ppid: pid_t
    let startedAt: Date
    let command: String
    let executable: String
    let name: String
    let agentKind: AgentKind?
    private let toolIndex: Int?

    init(pid: pid_t, ppid: pid_t, startedAt: Date, command: String) {
        self.pid = pid
        self.ppid = ppid
        self.startedAt = startedAt
        self.command = command
        // Paths may contain spaces ("Application Support"), so an app's executable ends
        // after .app/Contents/MacOS/<name>; anything else ends at the first space.
        if let range = command.range(of: ".app/Contents/MacOS/") {
            let rest = command[range.upperBound...]
            executable = String(command[..<range.upperBound]) + (rest.split(separator: " ").first.map(String.init) ?? String(rest))
        } else {
            executable = command.split(separator: " ").first.map(String.init) ?? command
        }
        name = executable.split(separator: "/").last.map(String.init) ?? executable
        agentKind = AgentSignature.kind(name: name, command: command)
        toolIndex = ToolSignature.index(matching: command)
    }

    var tool: ToolSignature.Entry? { toolIndex.map { ToolSignature.table[$0] } }
}

/// Recognizes dev servers, emulators, builds and watchers from their command lines.
enum ToolSignature {
    struct Entry: Sendable {
        let kind: ToolKind
        let label: String
        let needles: [String]
    }

    static let table: [Entry] = [
        Entry(kind: .devServer, label: "Metro (Expo)", needles: ["expo start", "expo/bin/cli", "@expo/cli", "react-native start", "metro/src/", "react-native/cli.js start"]),
        Entry(kind: .devServer, label: "Vite", needles: ["/vite/bin/vite", "node_modules/.bin/vite", " vite dev", "vite --"]),
        Entry(kind: .devServer, label: "Next.js", needles: ["next dev", "next-server", "next/dist/bin/next dev", "next/dist/server/lib/start-server"]),
        Entry(kind: .devServer, label: "SvelteKit", needles: ["svelte-kit dev"]),
        Entry(kind: .devServer, label: "Astro", needles: ["astro dev"]),
        Entry(kind: .devServer, label: "Nuxt", needles: ["nuxt dev", "nuxi dev"]),
        Entry(kind: .devServer, label: "Wrangler", needles: ["wrangler dev", "workerd serve"]),
        Entry(kind: .devServer, label: "Storybook", needles: ["storybook dev", "start-storybook"]),
        Entry(kind: .devServer, label: "Webpack", needles: ["webpack serve", "webpack-dev-server"]),
        Entry(kind: .devServer, label: String(localized: "Python server"), needles: ["uvicorn ", "manage.py runserver", "flask run", "-m http.server", "jupyter-lab", "jupyter-notebook"]),
        Entry(kind: .emulator, label: String(localized: "Firebase emulator"), needles: ["firebase emulators", "cloud-firestore-emulator", "firebase-tools/lib/bin/firebase.js emulators", "pubsub-emulator", "firebase-database-emulator"]),
        Entry(kind: .emulator, label: String(localized: "Android emulator"), needles: ["qemu-system-aarch64", "emulator -avd", "/emulator/emulator"]),
        Entry(kind: .build, label: "xcodebuild", needles: ["/usr/bin/xcodebuild"]),
        Entry(kind: .build, label: "Cargo", needles: ["/cargo build", "/cargo run", "/cargo test", "cargo build", "cargo run"]),
        Entry(kind: .build, label: String(localized: "Swift build"), needles: ["swift-build", "swift build"]),
        Entry(kind: .daemon, label: String(localized: "Gradle daemon"), needles: ["org.gradle.launcher.daemon.bootstrap.GradleDaemon"]),
        Entry(kind: .daemon, label: String(localized: "Kotlin daemon"), needles: ["org.jetbrains.kotlin.daemon.KotlinCompileDaemon"]),
        Entry(kind: .watcher, label: "TypeScript --watch", needles: ["tsc --watch", "tsc -w"]),
        Entry(kind: .watcher, label: "Vitest", needles: ["vitest/vitest.mjs", "/.bin/vitest"]),
        Entry(kind: .watcher, label: "Jest --watch", needles: ["jest --watch"]),
        Entry(kind: .watcher, label: "Nodemon", needles: ["nodemon"]),
        Entry(kind: .watcher, label: "Tailwind --watch", needles: ["tailwindcss --watch", "tailwindcss -w"]),
    ]

    static func match(_ command: String) -> Entry? {
        index(matching: command).map { table[$0] }
    }

    static func index(matching command: String) -> Int? {
        if systemPrefixes.contains(where: command.hasPrefix) { return nil }
        // GUI apps and their helpers never run dev tools; Xcode's xcodebuild is under Developer/.
        if command.containsBytes(".app/Contents/MacOS/") || command.containsBytes(".app/Contents/Frameworks/") { return nil }
        return table.firstIndex { entry in entry.needles.contains { command.containsBytes($0) } }
    }

    /// macOS's own daemons are never dev tools, and they are most of the process table.
    private static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]
}

enum AgentSignature {
    static func kind(of row: ProcessRow) -> AgentKind? { row.agentKind }

    static func kind(name: String, command: String) -> AgentKind? {
        if name == "claude" && !command.contains("--chrome-native-host") { return .claude }
        if name == "codex" && !command.contains("mcp-server") { return .codex }
        return nil
    }

    static let terminals: Set<String> = [
        "Terminal", "iTerm2", "ghostty", "Ghostty", "Warp", "stable", "cmux", "Code Helper", "Code Helper (Plugin)",
        "Electron", "tmux", "tmux: server", "screen", "sshd", "login", "kitty", "alacritty", "wezterm-gui", "Hyper",
        "Cursor", "Cursor Helper", "Cursor Helper (Plugin)", "zed", "Zed", "Nova", "Sublime Text", "Xcode",
        "idea", "webstorm", "pycharm", "goland", "rider", "clion", "rubymine", "phpstorm", "studio",
    ]
}

/// The pure part: given the process table, per-process CPU and memory, working
/// directories, listening ports and simulator metadata, works out who started what.
enum AgentLoadBuilder {
    struct Inputs: Sendable {
        var rows: [ProcessRow]
        var usage: [pid_t: (cpu: Double, memory: UInt64)]
        var workingDirectories: [pid_t: String]
        var ports: [pid_t: [Int]]
        var simulatorNames: [String: (name: String, runtime: String)]
        var now: Date
        /// Agent markers found in the environment of each tool process.
        var launches: [pid_t: AgentLaunch] = [:]
        /// MacUnclog itself, whose own command line may name a UDID (`--act shutdown-simulator`).
        var selfPID: pid_t = getpid()
    }

    static let simulatorIdleAfter: TimeInterval = 15 * 60
    static let simulatorQuietCPU: Double = 8

    static func build(_ inputs: Inputs) -> AgentLoad {
        let byPID = Dictionary(inputs.rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [pid_t: [pid_t]] = [:]
        for row in inputs.rows { children[row.ppid, default: []].append(row.pid) }

        func descendants(of pid: pid_t, stopAt: Set<pid_t> = []) -> [pid_t] {
            var result: [pid_t] = []
            var stack = children[pid] ?? []
            while let next = stack.popLast() {
                guard !stopAt.contains(next) else { continue }
                result.append(next)
                stack += children[next] ?? []
            }
            return result
        }

        func cpu(_ pids: [pid_t]) -> Double { pids.reduce(0) { $0 + (inputs.usage[$1]?.cpu ?? 0) } }
        func memory(_ pids: [pid_t]) -> UInt64 { pids.reduce(0) { $0 + (inputs.usage[$1]?.memory ?? 0) } }

        // Simulators: each booted device runs one launchd_sim whose path names the device.
        var simulatorRoots: [pid_t: String] = [:]
        for row in inputs.rows where row.name == "launchd_sim" {
            if let udid = udid(in: row.command) { simulatorRoots[row.pid] = udid }
        }
        let simulatorPIDs = Set(simulatorRoots.keys)

        // Sessions: the outermost agent process in each chain.
        let sessionRows = inputs.rows.filter { row in
            guard AgentSignature.kind(of: row) != nil else { return false }
            return !ancestors(of: row.pid, in: byPID).contains { AgentSignature.kind(of: $0) != nil }
        }
        let sessions = sessionRows.map { row in
            let tree = [row.pid] + descendants(of: row.pid, stopAt: simulatorPIDs)
            return AgentSession(pid: row.pid, kind: AgentSignature.kind(of: row)!, folder: inputs.workingDirectories[row.pid],
                                startedAt: row.startedAt, processCount: tree.count, cpuPercent: cpu(tree), memoryBytes: memory(tree))
        }.sorted { $0.cpuPercent > $1.cpuPercent }

        // Tools: the outermost matching process per chain, so `npm run dev` and the node
        // server it spawns count once.
        var tools: [ToolProcess] = []
        for row in inputs.rows {
            guard let signature = row.tool else { continue }
            let chain = ancestors(of: row.pid, in: byPID)
            if chain.contains(where: { $0.tool?.label == signature.label }) { continue }
            let tree = [row.pid] + descendants(of: row.pid, stopAt: simulatorPIDs)
            // The outermost agent in the chain is the session the tool belongs to.
            let owner: ToolOwner
            let launch = inputs.launches[row.pid]
            if let agent = chain.last(where: { AgentSignature.kind(of: $0) != nil }) {
                owner = .session(agent.pid, AgentSignature.kind(of: agent)!)
            } else if chain.contains(where: { AgentSignature.terminals.contains($0.name) }) {
                owner = .terminal
            } else if let launch, let session = launch.sessionPID, let alive = byPID[session], alive.agentKind != nil {
                // Detached from its session (nohup, setsid), but the session is still running.
                owner = .session(session, launch.kind)
            } else if let launch {
                // Without a session pid there is no way to tell which session started it, so
                // it only counts as left behind when no session of that agent is running.
                let sameAgentRunning = launch.sessionPID == nil && inputs.rows.contains { $0.agentKind == launch.kind }
                owner = sameAgentRunning ? .unknown : .orphaned
            } else {
                owner = .unknown
            }
            let ports = tree.flatMap { inputs.ports[$0] ?? [] }
            tools.append(ToolProcess(
                pid: row.pid, kind: signature.kind, label: signature.label,
                folder: tree.lazy.compactMap { inputs.workingDirectories[$0] }.first,
                ports: Array(Set(ports)).sorted(), owner: owner, startedAt: row.startedAt,
                processIDs: tree, cpuPercent: cpu(tree), memoryBytes: memory(tree)))
        }

        // A simulator is in use when something outside it names its UDID or it is busy.
        let ourselves = Set([inputs.selfPID] + ancestors(of: inputs.selfPID, in: byPID).map(\.pid))
        let simulators = simulatorRoots.map { pid, udid -> BootedSimulator in
            let tree = [pid] + descendants(of: pid)
            let inside = Set(tree)
            let users = inputs.rows
                .filter { $0.command.containsBytes(udid) && !inside.contains($0.pid) && $0.name != "launchd_sim" && !ourselves.contains($0.pid) }
                .map { ProcessRef(pid: $0.pid, name: $0.name) }
            let bootedAt = byPID[pid]?.startedAt ?? inputs.now
            let load = cpu(tree)
            var idle: String?
            if users.isEmpty && load < simulatorQuietCPU && inputs.now.timeIntervalSince(bootedAt) >= simulatorIdleAfter {
                idle = String(localized: "Started \(Format.relative(bootedAt, now: inputs.now)), with no users and no load")
            }
            let info = inputs.simulatorNames[udid]
            return BootedSimulator(udid: udid, name: info?.name ?? "Simulator", runtime: info?.runtime ?? "",
                                   bootedAt: bootedAt, cpuPercent: load, memoryBytes: memory(tree), users: users, idleReason: idle)
        }.sorted { $0.memoryBytes > $1.memoryBytes }

        return AgentLoad(sessions: sessions, simulators: simulators, tools: tools.sorted { $0.cpuPercent > $1.cpuPercent })
    }

    /// Parent first, up to (and including) launchd.
    static func ancestors(of pid: pid_t, in rows: [pid_t: ProcessRow]) -> [ProcessRow] {
        var result: [ProcessRow] = []
        var current = rows[pid]?.ppid ?? 0
        var seen: Set<pid_t> = [pid]
        while current > 0, let row = rows[current], seen.insert(current).inserted {
            result.append(row)
            current = row.ppid
        }
        return result
    }

    static func udid(in command: String) -> String? {
        guard let range = command.range(of: "/Devices/") else { return nil }
        let candidate = command[range.upperBound...].prefix(36)
        return candidate.count == 36 && UUID(uuidString: String(candidate)) != nil ? String(candidate) : nil
    }
}
