import Foundation

/// Things outside a project that run code from inside it: an `npm link`ed or
/// `~/.local/bin` symlinked tool, an MCP server in an agent's config, a LaunchAgent.
/// A project can look idle for weeks while one of these still needs its build output.
struct ExternalReferences: Sendable {
    struct Reference: Sendable {
        let path: String
        let source: String
        /// A project's own config that couldn't be read: it blocks that project only.
        var unreadable = false
    }

    var references: [Reference] = []
    /// A global config that exists but couldn't be read, or a search that didn't finish.
    /// Then nothing can be ruled out, so every project is blocked.
    var unreadable: String?

    static let empty = ExternalReferences()

    /// Why `project` must be left alone, if something outside uses it or might.
    func blockReason(for project: String) -> BlockReason? {
        if let unreadable { return .configUnreadable(unreadable) }
        let root = Self.resolve(project).lowercased()
        guard let reference = references.first(where: {
            let path = $0.path.lowercased()
            return path == root || path.hasPrefix(root + "/")
        }) else { return nil }
        return reference.unreadable ? .configUnreadable(reference.source) : .usedFromOutside(reference.source)
    }

    /// `projectConfigs` are the `.mcp.json` files the shared project walk found, or nil if
    /// that walk didn't finish.
    static func capture(projectConfigs: [String]?) -> ExternalReferences {
        let home = NSHomeDirectory()
        var result = ExternalReferences()

        func add(_ path: String, from source: String) {
            result.references.append(Reference(path: resolve(path), source: abbreviate(source)))
        }

        var linkFolders = ["\(home)/.local/bin", "\(home)/bin", "/opt/homebrew/bin", "/usr/local/bin",
                           "/opt/homebrew/lib/node_modules", "/usr/local/lib/node_modules",
                           "\(home)/.npm-global/bin", "\(home)/.npm-global/lib/node_modules",
                           "\(home)/Library/pnpm", "\(home)/Library/pnpm/global/5/node_modules",
                           "\(home)/.bun/bin", "\(home)/.bun/install/global/node_modules",
                           "\(home)/.volta/bin"]
        // Node version managers keep one global prefix per installed version.
        let xdgData = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? "\(home)/.local/share"
        for (base, suffix) in [("\(home)/.nvm/versions/node", ""), ("\(xdgData)/fnm/node-versions", "/installation"),
                               ("\(home)/.fnm/node-versions", "/installation"),
                               ("\(home)/Library/Application Support/fnm/node-versions", "/installation"),
                               ("\(home)/.local/share/mise/installs/node", ""), ("\(home)/.volta/tools/image/node", "")] {
            for version in (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? [] {
                linkFolders += ["\(base)/\(version)\(suffix)/bin", "\(base)/\(version)\(suffix)/lib/node_modules"]
            }
        }
        for folder in linkFolders {
            for target in linkTargets(in: folder) { add(target, from: folder) }
        }

        let globalConfigs = [
            "\(home)/.claude.json", "\(home)/.claude/settings.json", "\(home)/.cursor/mcp.json",
            "\(home)/Library/Application Support/Claude/claude_desktop_config.json", "\(home)/.config/zed/settings.json",
        ]
        for file in globalConfigs where FileManager.default.fileExists(atPath: file) {
            guard let paths = pathsInMCPServers(jsonAt: file) else {
                result.unreadable = abbreviate(file)
                continue
            }
            paths.forEach { add($0, from: file) }
        }
        if let projectConfigs {
            for file in projectConfigs where !isDanglingLink(file) {
                guard let paths = pathsInMCPServers(jsonAt: file) else {
                    let project = (file as NSString).deletingLastPathComponent
                    result.references.append(Reference(path: resolve(project), source: abbreviate(file), unreadable: true))
                    continue
                }
                paths.forEach { add($0, from: file) }
            }
        } else {
            result.unreadable = String(localized: "the search for .mcp.json files")
        }
        if let codex = pathsInCodexMCPServers() {
            codex.forEach { add($0, from: "\(home)/.codex/config.toml") }
        } else {
            result.unreadable = "~/.codex/config.toml"
        }

        let launchAgents = "\(home)/Library/LaunchAgents"
        for plist in (try? FileManager.default.contentsOfDirectory(atPath: launchAgents)) ?? [] where plist.hasSuffix(".plist") {
            let file = "\(launchAgents)/\(plist)"
            guard let dictionary = NSDictionary(contentsOfFile: file) else { continue }
            absolutePaths(in: dictionary).forEach { add($0, from: file) }
        }
        return result
    }

    /// True only when a symlink points at nothing. A target that exists but can't be read
    /// must still reach the parser, which then blocks the project as unreadable.
    static func isDanglingLink(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) != 0 else { return false }
        guard errno == ENOENT || errno == ENOTDIR else { return false }
        // A link onto a disk that isn't mounted right now isn't broken, just unreadable.
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return true }
        let target = destination.hasPrefix("/")
            ? destination
            : ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(destination)
        let parts = target.split(separator: "/")
        if parts.count >= 2, parts[0] == "Volumes", !FileManager.default.fileExists(atPath: "/Volumes/\(parts[1])") {
            return false
        }
        return true
    }



    /// Symlinks in a folder (and in its @scope folders), resolved.
    private static func linkTargets(in folder: String) -> [String] {
        let fm = FileManager.default
        var result: [String] = []
        for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] {
            let path = "\(folder)/\(name)"
            if name.hasPrefix("@") {
                result += linkTargets(in: path)
            } else if (try? fm.destinationOfSymbolicLink(atPath: path)) != nil {
                result.append(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
            }
        }
        return result
    }

    /// Absolute paths inside every "mcpServers" or "context_servers" object of a JSON file,
    /// or nil if the file isn't JSON. Only those objects: ~/.claude.json also lists every
    /// project ever opened, which says nothing about whether something runs from it.
    static func pathsInMCPServers(jsonAt file: String) -> [String]? {
        guard let data = FileManager.default.contents(atPath: file) else { return nil }
        if String(decoding: data, as: UTF8.self).allSatisfy(\.isWhitespace) { return [] }
        // Zed and others write JSON with comments and trailing commas.
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) else { return nil }
        var result: [String] = []
        func walk(_ value: Any, inServers: Bool) {
            if let dictionary = value as? [String: Any] {
                for (key, child) in dictionary {
                    walk(child, inServers: inServers || key == "mcpServers" || key == "context_servers")
                }
            } else if let array = value as? [Any] {
                array.forEach { walk($0, inServers: inServers) }
            } else if inServers, let string = value as? String {
                result += absolutePaths(inText: string)
            }
        }
        walk(json, inServers: false)
        return result
    }

    /// Nil when the file exists but can't be read.
    private static func pathsInCodexMCPServers() -> [String]? {
        let file = "\(NSHomeDirectory())/.codex/config.toml"
        guard FileManager.default.fileExists(atPath: file) else { return [] }
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        var inServer = false
        var result: [String] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { inServer = trimmed.hasPrefix("[mcp_servers") }
            if inServer { result += absolutePaths(inText: trimmed) }
        }
        return result
    }

    private static func absolutePaths(in plist: Any) -> [String] {
        if let dictionary = plist as? NSDictionary { return dictionary.allValues.flatMap(absolutePaths(in:)) }
        if let array = plist as? NSArray { return array.flatMap(absolutePaths(in:)) }
        if let string = plist as? String { return absolutePaths(inText: string) }
        return []
    }

    /// "/Users/me/dev/x/dist/index.js" and "~/dev/x" out of a command or argument string.
    static func absolutePaths(inText text: String) -> [String] {
        let home = NSHomeDirectory()
        return text.split(whereSeparator: { " \"'=,".contains($0) })
            .map(String.init)
            .compactMap { token in
                if token.hasPrefix("/") { return PathGuard.normalized(token) }
                if token.hasPrefix("~/") { return PathGuard.normalized(home + token.dropFirst()) }
                return nil
            }
    }

    /// Resolves symlinks in the longest part of the path that exists, so a config that
    /// says ~/dev/tool matches a project whose real path is ~/Developer/tool.
    static func resolve(_ path: String) -> String {
        var existing = PathGuard.normalized(path)
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing), existing != "/" {
            rest.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        let resolved = URL(fileURLWithPath: existing).resolvingSymlinksInPath().path
        return PathGuard.normalized(([resolved] + rest).joined(separator: "/"))
    }

    private static func abbreviate(_ path: String) -> String {
        path.hasPrefix(NSHomeDirectory()) ? "~" + path.dropFirst(NSHomeDirectory().count) : path
    }
}
