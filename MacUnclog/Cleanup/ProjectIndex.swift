import Foundation

/// One walk over the project folders per scan, shared by build-output cleanup, simulator
/// runtimes (project device sets) and external references (`.mcp.json`). Walking a large
/// ~/dev with find takes many seconds, so it must happen once, not once per question.
struct ProjectIndex: Sendable {
    /// Folders named like build output, not yet checked against the build-folder rules.
    var buildFolders: [URL] = []
    /// Symlinks named like build output, e.g. a worktree's node_modules pointing elsewhere.
    var buildLinks: [URL] = []
    /// Folders that hold a device_set.plist.
    var deviceSets: [URL] = []
    var mcpConfigs: [String] = []
    /// False if a walk timed out: then nothing found here may be trusted to be complete.
    var complete = true
    /// False if find reported any error (often a folder it may not read). Device sets then
    /// count as unknown, since a missed one means deleting a runtime a simulator needs.
    var errorFree = true

    static func scan(roots: [URL]) async -> ProjectIndex {
        var names: [String] = []
        for (index, name) in (CleanupScanner.buildFolderNames.sorted() + ["DerivedData"]).enumerated() {
            if index > 0 { names.append("-o") }
            names += ["-name", name]
        }
        names += ["-o", "-name", "dd-*"]

        var result = ProjectIndex()
        // The real path, so find, git and symlink targets all spell a folder the same way.
        for root in CleanupScanner.distinctRoots(roots).map({ PathGuard.normalized($0.resolvingSymlinksInPath().path) }) {
            let expression = [root, "-xdev", "-maxdepth", "10",
                              "(", "-name", ".git", ")", "-prune", "-o",
                              "(", "-type", "d", "("] + names + [")", "-print", "-prune", ")", "-o",
                              "(", "-type", "l", "("] + names + [")", "-print", ")", "-o",
                              "(", "-name", "device_set.plist", "-print", ")", "-o",
                              "(", "-name", ".mcp.json", "(", "-type", "f", "-o", "-type", "l", ")", "-print", ")"]
            let output = await Shell.run("/usr/bin/find", expression, timeout: .seconds(180))
            if output.timedOut { result.complete = false }
            if !output.succeeded { result.errorFree = false }
            for line in output.stdout.split(separator: "\n") {
                let url = URL(fileURLWithPath: String(line))
                switch url.lastPathComponent {
                case "device_set.plist": result.deviceSets.append(url.deletingLastPathComponent())
                case ".mcp.json": result.mcpConfigs.append(url.path)
                default:
                    if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                        result.buildLinks.append(url)
                    } else {
                        result.buildFolders.append(url)
                    }
                }
            }
        }
        return result
    }
}
