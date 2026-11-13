import Foundation

/// A big file or a leftover installer in the user's own folders. These are the user's
/// data, so MacUnclog only ever moves them to the Bin, after asking, and never during
/// automatic clean-up.
struct PersonalFile: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable, Hashable, CaseIterable {
        case installer, large
    }

    let path: String
    let kind: Kind
    /// Space on disk, which is what moving it to the Bin and emptying the Bin frees.
    let bytes: Int64
    let modified: Date?
    var blocked: BlockReason? = nil
    /// The file's inode, so a re-check can tell a replaced file from the one that was listed.
    var inode: UInt64 = 0

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.hasPrefix(PathGuard.home) ? "~" + parent.dropFirst(PathGuard.home.count) : parent
    }
    var canMove: Bool { blocked == nil }
}

enum PersonalFiles {
    static let largeFileBytes: Int64 = 500_000_000
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]
    /// Folders an installer usually lands in. Listed directly as well, because Spotlight
    /// may not index them.
    static let installerFolders = ["Downloads", "Desktop", ""]

    /// Packages that are apps or media libraries: their own app manages what's inside,
    /// and an app belongs in an uninstaller, not here.
    static let skippedPackages: Set<String> = [
        "app", "photoslibrary", "photolibrary", "migratedphotolibrary", "aplibrary", "musiclibrary", "tvlibrary",
        "imovielibrary", "fcpbundle", "lrdata", "lrlibrary", "cocatalog",
    ]
    /// Files an app keeps as its library: moving one breaks the app's references.
    static let skippedFileExtensions: Set<String> = ["lrcat", "lrcat-data"]
    /// Folders whose files an app keeps track of (Music, TV), or that a cleanup category
    /// already covers (build output).
    static let skippedFolderNames: Set<String> = [
        "Media.localized", "iTunes Media", "Photo Booth Library", "node_modules", "DerivedData", "Pods", ".build", "target", "build",
    ]

    /// Finds installers anywhere in the home folder outside Library, and files of at least
    /// `largeFileBytes`, using Spotlight plus a direct look at Downloads, Desktop and the
    /// home folder itself.
    static func find(inUse: InUseSnapshot, userProtected: [String] = PathGuard.userProtected) async -> [PersonalFile] {
        let home = PathGuard.home
        let names = installerExtensions.sorted().map { "kMDItemFSName == \"*.\($0)\"c" }.joined(separator: " || ")
        async let installers = spotlight(names)
        async let large = spotlight("kMDItemFSSize >= \(largeFileBytes)")
        var candidates = Set(await installers + large)
        for folder in installerFolders {
            let url = URL(fileURLWithPath: home).appendingPathComponent(folder)
            for child in CleanupScanner.children(of: url) { candidates.insert(child.path) }
        }

        var gitRoots: [String: Bool] = [:]
        let files = candidates.compactMap { path -> PersonalFile? in
            guard var file = inspect(path, userProtected: userProtected, gitRoots: &gitRoots) else { return nil }
            file.blocked = inUse.blockReason(under: file.path)
            return file
        }
        return files.sorted { ($0.kind == .installer ? 0 : 1, -$0.bytes) < ($1.kind == .installer ? 0 : 1, -$1.bytes) }
    }

    /// The file at `path`, if it's one MacUnclog may offer: a regular file or a document
    /// package in the home folder, outside Library, hidden folders, git projects, app and
    /// media libraries and protected folders, and taking up space on this disk.
    static func inspect(_ path: String, home: String = PathGuard.home, largeFileBytes: Int64 = PersonalFiles.largeFileBytes,
                        userProtected: [String], gitRoots: inout [String: Bool]) -> PersonalFile? {
        let path = PathGuard.normalized(path)
        guard path.hasPrefix(home + "/") else { return nil }
        let parts = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        guard let first = parts.first, first != "Library", first != "Public",
              !parts.contains(where: { $0.hasPrefix(".") || skippedFolderNames.contains($0) })
        else { return nil }
        // Nothing inside a package: a .logicx project moves whole or not at all.
        let ancestors = parts.dropLast().indices.map { parts[...$0].joined(separator: "/") }
        guard !ancestors.contains(where: { isPackage(home + "/" + $0) }) else { return nil }
        // Documents, Desktop, Downloads, Movies and Music are off limits to clean-up, but
        // they're where people keep the files this list is for, and the Bin gives them back.
        // A symlink anywhere in the path could lead into Library or a protected folder.
        guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path,
              !PathGuard.overlaps(path, userProtected),
              !insideGitProject(path, home: home, cache: &gitRoots),
              PathGuard.isOnHomeVolume(path)
        else { return nil }

        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let type = info.st_mode & S_IFMT
        let ext = (path as NSString).pathExtension.lowercased()
        let bytes: Int64
        if type == S_IFREG {
            // A file that iCloud has evicted takes no space here, and binning it frees nothing.
            guard info.st_flags & UInt32(SF_DATALESS) == 0 else { return nil }
            // With another hard link the data stays on disk after the Bin is emptied.
            guard info.st_nlink == 1, !skippedFileExtensions.contains(ext) else { return nil }
            bytes = Int64(info.st_blocks) * 512
        } else if type == S_IFDIR, isPackage(path), !skippedPackages.contains(ext) {
            bytes = allocatedSize(of: path)
        } else {
            return nil
        }
        let kind: PersonalFile.Kind
        if installerExtensions.contains(ext) {
            kind = .installer
        } else if bytes >= largeFileBytes {
            kind = .large
        } else {
            return nil
        }
        guard bytes > 0 else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        return PersonalFile(path: path, kind: kind, bytes: bytes, modified: modified, inode: UInt64(info.st_ino))
    }

    private static func isPackage(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if skippedPackages.contains(ext) { return true }
        return (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    private static func insideGitProject(_ path: String, home: String, cache: inout [String: Bool]) -> Bool {
        var folder = (path as NSString).deletingLastPathComponent
        var visited: [String] = []
        defer { visited.forEach { cache[$0] = cache[$0] ?? false } }
        while folder.hasPrefix(home + "/") {
            if let known = cache[folder] {
                if known { visited.forEach { cache[$0] = true } }
                return known
            }
            visited.append(folder)
            if FileManager.default.fileExists(atPath: folder + "/.git") {
                visited.forEach { cache[$0] = true }
                return true
            }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return false
    }

    private static func allocatedSize(of folder: String) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    private static func spotlight(_ query: String) async -> [String] {
        let output = await Shell.run("/usr/bin/mdfind", ["-0", "-onlyin", PathGuard.home, query], timeout: .seconds(20))
        guard output.succeeded else { return [] }
        return output.stdout.split(separator: "\0").map(String.init).filter { !$0.hasPrefix(PathGuard.home + "/Library/") }
    }

    /// Moves each file to the Bin after checking it again: still there, unchanged since the
    /// list was made, still eligible and not open. Returns each file with its problem, if any.
    static func moveToBin(_ files: [PersonalFile]) async -> [(PersonalFile, MoveError?)] {
        let inUse = await InUseSnapshot.capture()
        let userProtected = PathGuard.userProtected
        var gitRoots: [String: Bool] = [:]
        return files.map { file in
            guard let current = inspect(file.path, userProtected: userProtected, gitRoots: &gitRoots),
                  current.kind == file.kind, current.bytes == file.bytes, current.modified == file.modified,
                  current.inode == file.inode
            else { return (file, .changed) }
            if let reason = inUse.blockReason(under: file.path) { return (file, .inUse(reason)) }
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: file.path), resultingItemURL: nil)
                return (file, nil)
            } catch {
                return (file, .failed(error.localizedDescription))
            }
        }
    }

    enum MoveError: Error, Sendable, Hashable, CustomStringConvertible {
        case changed
        case inUse(BlockReason)
        case failed(String)

        var description: String {
            switch self {
            case .changed: String(localized: "It moved or changed since the list was made")
            case .inUse(let reason): reason.description
            case .failed(let message): message
            }
        }
    }
}
