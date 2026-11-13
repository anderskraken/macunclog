import Foundation

/// Reads the process tree, working directories, listening ports and simulator names, and
/// hands them to AgentLoadBuilder. About half a second on a busy Mac.
enum AgentProbe {
    static func capture(usage: [pid_t: (cpu: Double, memory: UInt64)], now: Date = .now) async -> AgentLoad {
        let rows = await processRows(now: now)
        guard !rows.isEmpty else { return .empty }

        let interesting = rows.filter { $0.agentKind != nil || $0.tool != nil }
        var treePIDs = Set(interesting.map(\.pid))
        var children: [pid_t: [pid_t]] = [:]
        for row in rows { children[row.ppid, default: []].append(row.pid) }
        for row in interesting where row.tool != nil {
            var stack = children[row.pid] ?? []
            while let next = stack.popLast(), treePIDs.count < 2000 {
                if treePIDs.insert(next).inserted { stack += children[next] ?? [] }
            }
        }

        async let directories = workingDirectories(of: treePIDs)
        async let ports = listeningPorts(of: treePIDs)
        let udids = rows.filter { $0.name == "launchd_sim" }.compactMap { AgentLoadBuilder.udid(in: $0.command) }

        var launches: [pid_t: AgentLaunch] = [:]
        for row in interesting where row.tool != nil {
            if let launch = AgentLaunch.parse(environment: environment(of: row.pid)) { launches[row.pid] = launch }
        }

        var inputs = await AgentLoadBuilder.Inputs(
            rows: rows, usage: usage, workingDirectories: directories, ports: ports,
            simulatorNames: simulatorNames(udids), now: now)
        inputs.launches = launches
        return AgentLoadBuilder.build(inputs)
    }

    /// The environment of one of the user's own processes, from KERN_PROCARGS2
    /// (argc, the executable path, argv, then the environment).
    static func environment(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        func nextString(from start: inout Int) -> String {
            let begin = start
            while start < size && buffer[start] != 0 { start += 1 }
            defer { start += 1 }
            return String(decoding: buffer[begin..<min(start, size)], as: UTF8.self)
        }
        var index = MemoryLayout<Int32>.size
        _ = nextString(from: &index)
        while index < size && buffer[index] == 0 { index += 1 }
        // Exactly argc arguments, empty ones included: Node's process.title rewrites argv
        // into a title plus NUL padding.
        for _ in 0..<argc where index < size { _ = nextString(from: &index) }
        while index < size && buffer[index] == 0 { index += 1 }
        var environment: [String] = []
        while index < size {
            let entry = nextString(from: &index)
            if entry.isEmpty { break }
            environment.append(entry)
        }
        return environment
    }

    static func processRows(now: Date) async -> [ProcessRow] {
        let output = await Shell.run("/bin/ps", ["-A", "-o", "pid=,ppid=,etime=,command="], timeout: .seconds(10))
        return output.stdout.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = pid_t(fields[0]), let ppid = pid_t(fields[1]) else { return nil }
            return ProcessRow(pid: pid, ppid: ppid, startedAt: now.addingTimeInterval(-parseElapsed(String(fields[2]))),
                              command: String(fields[3]))
        }
    }

    /// Parses `ps` elapsed time: "[[dd-]hh:]mm:ss".
    static func parseElapsed(_ text: String) -> TimeInterval {
        var days = 0.0
        var rest = Substring(text)
        if let dash = rest.firstIndex(of: "-") {
            days = Double(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        return rest.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) } + days * 86_400
    }

    private static func workingDirectories(of pids: Set<pid_t>) async -> [pid_t: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        let output = await Shell.run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", list, "-n", "-P", "-w", "-F", "pn"], timeout: .seconds(10))
        var result: [pid_t: String] = [:]
        var pid: pid_t = 0
        for line in output.stdout.split(separator: "\n") {
            if line.hasPrefix("p") { pid = pid_t(line.dropFirst()) ?? 0 }
            if line.hasPrefix("n/") { result[pid] = InUseSnapshot.decodeEscapes(String(line.dropFirst())) }
        }
        return result
    }

    private static func listeningPorts(of pids: Set<pid_t>) async -> [pid_t: [Int]] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        let output = await Shell.run("/usr/sbin/lsof", ["-a", "-iTCP", "-sTCP:LISTEN", "-p", list, "-n", "-P", "-w", "-F", "pn"], timeout: .seconds(10))
        var result: [pid_t: [Int]] = [:]
        var pid: pid_t = 0
        for line in output.stdout.split(separator: "\n") {
            if line.hasPrefix("p") { pid = pid_t(line.dropFirst()) ?? 0 }
            if line.hasPrefix("n"), let port = line.split(separator: ":").last.flatMap({ Int($0) }) {
                if !(result[pid]?.contains(port) ?? false) { result[pid, default: []].append(port) }
            }
        }
        return result
    }

    private static func simulatorNames(_ udids: [String]) -> [String: (name: String, runtime: String)] {
        let devices = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        var result: [String: (name: String, runtime: String)] = [:]
        for udid in udids {
            guard let plist = NSDictionary(contentsOf: devices.appendingPathComponent("\(udid)/device.plist")) else { continue }
            let name = plist["name"] as? String ?? "Simulator"
            let runtime = (plist["runtime"] as? String).map(prettyRuntime) ?? ""
            result[udid] = (name, runtime)
        }
        return result
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4" becomes "iOS 27.2".
    static func prettyRuntime(_ identifier: String) -> String {
        guard let last = identifier.split(separator: ".").last else { return identifier }
        let parts = last.split(separator: "-")
        guard let platform = parts.first else { return identifier }
        let numbers = parts.dropFirst().prefix { Int($0) != nil }
        return numbers.isEmpty ? String(platform) : "\(platform) \(numbers.joined(separator: "."))"
    }
}
