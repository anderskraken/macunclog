import Foundation

/// The last line of defence: every deletion goes through here, and anything that
/// resolves into the user's own data is refused no matter which scanner produced it.
enum PathGuard {
    static let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path

    static let protectedRelativeToHome = [
        "Documents", "Desktop", "Movies", "Pictures", "Music", "Downloads", "Public",
        "Library/Mobile Documents", "Library/CloudStorage", "Library/Mail", "Library/Messages",
        "Library/Photos", "Library/Keychains", "Library/Containers", "Library/Group Containers",
        "Library/Application Support/Claude", "Library/Application Support/Claude-3p",
        ".claude/projects", ".codex/sessions", ".ssh", ".gnupg",
    ]

    /// Folders the user added under Settings > General > Protected folders.
    static var userProtected: [String] {
        AutomationSettings.load().protectedFolders.map {
            normalized(URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).resolvingSymlinksInPath().path)
        }
    }

    enum Violation: Error, Equatable, CustomStringConvertible {
        case notAbsolute(String)
        case outsideHome(String)
        case tooShallow(String)
        case protected(String)
        case otherVolume(String)

        var description: String {
            switch self {
            case .notAbsolute(let path): String(localized: "Not an absolute path: \(path)")
            case .outsideHome(let path): String(localized: "Outside the home folder: \(path)")
            case .tooShallow(let path): String(localized: "Too close to the root to delete: \(path)")
            case .protected(let path): String(localized: "Protected: \(path)")
            case .otherVolume(let path): String(localized: "On another disk or a network volume: \(path)")
            }
        }
    }

    static func isProtected(_ path: String, userFolders: [String] = userProtected) -> Bool {
        overlaps(normalized(path), protectedRelativeToHome.map { home + "/" + $0 } + userFolders)
    }

    /// True if `path` is one of `roots`, inside one or contains one. The startup disk ignores
    /// case, so a folder typed as ~/projects protects ~/Projects too.
    static func overlaps(_ path: String, _ roots: [String]) -> Bool {
        let path = path.lowercased()
        return roots.contains { root in
            let root = root.lowercased()
            return path == root || path.hasPrefix(root + "/") || root.hasPrefix(path + "/")
        }
    }

    /// Checks the path and the path it resolves to after following symlinks.
    static func validateForDeletion(_ url: URL) throws(Violation) {
        let raw = url.path
        guard raw.hasPrefix("/") else { throw .notAbsolute(raw) }
        for path in Set([normalized(raw), normalized(url.resolvingSymlinksInPath().path)]) {
            guard path.hasPrefix(home + "/") else { throw .outsideHome(path) }
            let depth = path.dropFirst(home.count).split(separator: "/").count
            guard depth >= 2 else { throw .tooShallow(path) }
            guard !isProtected(path) else { throw .protected(path) }
            guard isOnHomeVolume(path) else { throw .otherVolume(path) }
        }
    }

    /// A network or FUSE mount inside a project must never be cleaned: lsof can't see
    /// what runs on the other machine.
    static func isOnHomeVolume(_ path: String) -> Bool {
        func device(_ path: String) -> dev_t? {
            var info = stat()
            var current = path
            while lstat(current, &info) != 0 {
                let parent = (current as NSString).deletingLastPathComponent
                guard parent != current, !parent.isEmpty else { return nil }
                current = parent
            }
            return info.st_dev
        }
        guard let home = device(home), let target = device(path) else { return false }
        return home == target
    }

    static func normalized(_ path: String) -> String {
        var result = (path as NSString).standardizingPath
        if result.hasPrefix("/System/Volumes/Data/") {
            result = String(result.dropFirst("/System/Volumes/Data".count))
        }
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

enum SafeDeleter {
    static func removeItem(at url: URL) throws {
        try PathGuard.validateForDeletion(url)
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch let error as CocoaError where error.code == .fileWriteNoPermission {
            try makeWritable(url)
            try FileManager.default.removeItem(at: url)
        }
    }

    static func removeContents(of url: URL) throws {
        try PathGuard.validateForDeletion(url)
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        } catch CocoaError.fileReadNoSuchFile {
            return
        }
        var firstError: Error?
        for child in children {
            do { try removeItem(at: child) } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
    }

    /// Some caches (Go modules, a few npm packages) ship read-only folders.
    private static func makeWritable(_ url: URL) throws {
        try PathGuard.validateForDeletion(url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["-R", "u+w", url.path]
        try process.run()
        process.waitUntilExit()
    }
}
