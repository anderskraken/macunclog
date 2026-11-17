import Foundation

/// A local git repository in a project folder. It's offered for the Bin only when nothing
/// in it exists only on this Mac: every commit, branch, tag and stash is on GitHub, no file
/// is changed or untracked, and the ignored files are build output that a fresh clone
/// rebuilds. Moving one is always the user's choice, never part of automatic clean-up.
struct LocalRepo: Identifiable, Sendable, Hashable {
    let path: String
    /// The remote the checked-out branch tracks. Known once the remote checks ran.
    var remote: RepoRemote?
    /// Measured only for repositories that can be moved.
    var bytes: Int64 = 0
    var lastActivity: Date?
    var blocked: RepoProblem?
    /// The `.git` folder's inode, so the re-check before moving can tell a repository that
    /// was replaced at the same path from the one that was listed.
    var gitInode: UInt64 = 0

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { Repositories.abbreviate((path as NSString).deletingLastPathComponent) }
    var canMove: Bool { blocked == nil }
}

struct RepoRemote: Sendable, Hashable, Codable {
    let name: String
    let url: String
    /// owner/name on GitHub.
    let slug: String

    var webURL: URL? { URL(string: "https://github.com/\(slug)") }
}

/// Why a repository stays. Each case is one of the "nothing only here" rules.
enum RepoProblem: Sendable, Hashable {
    case gitMissing
    case checkFailed(String)
    case uncommitted(files: Int, example: String)
    case stashed(Int)
    case noBranch
    case noUpstream(String)
    case upstreamGone(String)
    case ahead(branch: String, commits: Int)
    case unpushed(Int)
    case notOnRemote(Int)
    case tagNotOnRemote(String)
    case worktreeElsewhere(String)
    case submoduleChanged(String)
    case notGitHub(String)
    case remoteUnreachable(String)
    case archived(String)
    case missingOnGitHub(String)
    case gitHubUnknown(String)
    case ignoredFiles([String])
    case notIdle(BlockReason)

    var description: String {
        switch self {
        case .gitMissing: String(localized: "Git isn’t installed, so MacUnclog can’t check this repository")
        case .checkFailed(let what): String(localized: "Couldn’t check \(what)")
        case .uncommitted(let files, let example):
            files == 1 ? String(localized: "\(example) isn’t committed")
                : String(localized: "\(files) files aren’t committed, such as \(example)")
        case .stashed(let count):
            count == 1 ? String(localized: "1 stash exists only here") : String(localized: "\(count) stashes exist only here")
        case .noBranch: String(localized: "No branch here, so there’s nothing to compare with GitHub")
        case .noUpstream(let branch): String(localized: "Branch \(branch) doesn’t track a branch on a remote")
        case .upstreamGone(let branch): String(localized: "The remote branch that \(branch) tracks is gone")
        case .ahead(let branch, let commits):
            commits == 1 ? String(localized: "Branch \(branch) has 1 commit that isn’t pushed")
                : String(localized: "Branch \(branch) has \(commits) commits that aren’t pushed")
        case .unpushed(let commits):
            commits == 1 ? String(localized: "1 commit isn’t on any remote branch")
                : String(localized: "\(commits) commits aren’t on any remote branch")
        case .notOnRemote(let commits):
            commits == 1 ? String(localized: "1 commit isn’t on GitHub right now, or GitHub has changes this copy hasn’t fetched")
                : String(localized: "\(commits) commits aren’t on GitHub right now, or GitHub has changes this copy hasn’t fetched")
        case .tagNotOnRemote(let tag): String(localized: "Tag \(tag) isn’t on the remote")
        case .worktreeElsewhere(let path): String(localized: "Has a worktree outside its folder, at \(path)")
        case .submoduleChanged(let path): String(localized: "Submodule \(path) has work that exists only here")
        case .notGitHub(let url): String(localized: "The remote isn’t on GitHub: \(url)")
        case .remoteUnreachable(let remote): String(localized: "Couldn’t reach the remote \(remote) just now")
        case .archived(let slug): String(localized: "\(slug) is archived on GitHub")
        case .missingOnGitHub(let slug): String(localized: "GitHub can’t find \(slug)")
        case .gitHubUnknown(let slug): String(localized: "Couldn’t look up \(slug) on GitHub")
        case .ignoredFiles(let names):
            names.count == 1 ? String(localized: "Ignored by git and exists only here: \(names[0])")
                : String(localized: "Ignored by git and exist only here: \(Repositories.list(names))")
        case .notIdle(let reason): reason.description
        }
    }

    /// A fixed identifier for `--repos --json`.
    var id: String {
        switch self {
        case .gitMissing: "gitMissing"
        case .checkFailed: "checkFailed"
        case .uncommitted: "uncommitted"
        case .stashed: "stashed"
        case .noBranch: "noBranch"
        case .noUpstream: "noUpstream"
        case .upstreamGone: "upstreamGone"
        case .ahead: "ahead"
        case .unpushed: "unpushed"
        case .notOnRemote: "notOnRemote"
        case .tagNotOnRemote: "tagNotOnRemote"
        case .worktreeElsewhere: "worktreeElsewhere"
        case .submoduleChanged: "submoduleChanged"
        case .notGitHub: "notGitHub"
        case .remoteUnreachable: "remoteUnreachable"
        case .archived: "archived"
        case .missingOnGitHub: "missingOnGitHub"
        case .gitHubUnknown: "gitHubUnknown"
        case .ignoredFiles: "ignoredFiles"
        case .notIdle(let reason): reason.id
        }
    }
}

enum GitHubStatus: Sendable, Hashable {
    case active, archived, missing
    /// gh isn't installed or isn't signed in, so only git's own checks apply.
    case unchecked
    case failed
}

/// How a remote URL maps to a GitHub repository and what GitHub says about it. Tests swap
/// in a local bare repository for GitHub.
struct GitHubCheck: Sendable {
    var slug: @Sendable (String) async -> String?
    var status: @Sendable (String) async -> GitHubStatus

    static let live = GitHubCheck(slug: Repositories.gitHubSlug(for:), status: Repositories.gitHubStatus(of:))
}

/// One repository in a History entry, with what it takes to clone it again.
struct RepoRecord: Identifiable, Sendable, Codable, Hashable {
    let path: String
    let remoteURL: String
    let slug: String?
    let bytes: Int64
    let result: CleanupOutcome.Result

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

enum Repositories {
    static let defaultIdleDays = 60

    /// Ignored files that are fine to lose besides build output: Finder's folder settings
    /// and caches that tools write on their own.
    static let disposableNames: Set<String> = [".DS_Store", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache"]

    /// Every repository in the project folders, each with its verdict. Sizes are measured
    /// only for the ones that can be moved.
    static func find(in context: ScanContext, idleWindow: TimeInterval, github: GitHubCheck = .live) async -> [LocalRepo] {
        var index = context.index
        if index == nil { index = await ProjectIndex.scan(roots: context.projectRoots) }
        let paths = outermost((index?.gitRepos ?? []).map { PathGuard.normalized($0.resolvingSymlinksInPath().path) })
        let repos = await CleanupScanner.concurrentMap(paths) { path in
            var repo = await inspect(path, context: context, idleWindow: idleWindow, github: github)
            if repo.canMove, context.measureSizes { repo.bytes = await DiskUsage.size(of: path) }
            return repo
        }
        return repos.values.sorted { ($0.canMove ? 0 : 1, -$0.bytes, $0.path) < ($1.canMove ? 0 : 1, -$1.bytes, $1.path) }
    }

    /// A repository inside another one moves with it, so only the outer one is listed.
    static func outermost(_ paths: [String]) -> [String] {
        let sorted = Set(paths).sorted()
        var result: [String] = []
        for path in sorted where !result.contains(where: { path.hasPrefix($0 + "/") }) {
            result.append(path)
        }
        return result
    }

    // MARK: The checks

    /// Runs every rule against the repository at `path` and stops at the first that fails.
    /// The local checks run first; the network is asked only when nothing local is left.
    static func inspect(_ path: String, context: ScanContext, idleWindow: TimeInterval, github: GitHubCheck) async -> LocalRepo {
        let path = PathGuard.normalized(path)
        var repo = LocalRepo(path: path, gitInode: inode(path + "/.git"))
        func blocked(_ problem: RepoProblem) -> LocalRepo {
            var result = repo
            result.blocked = problem
            return result
        }
        guard Shell.developerToolsInstalled else { return blocked(.gitMissing) }

        // Worktrees: a linked one inside the folder moves along and is checked like the
        // main one; one elsewhere would be left pointing at a repository in the Bin.
        let listing = await git(["worktree", "list", "--porcelain", "-z"], in: path)
        guard listing.succeeded else { return blocked(.checkFailed(String(localized: "the worktrees"))) }
        let worktrees = parseWorktrees(listing.stdout)
        guard let main = worktrees.first, real(main.path) == real(path) else {
            return blocked(.checkFailed(String(localized: "the worktrees")))
        }
        var inside: [String] = []
        for worktree in worktrees.dropFirst() where !worktree.prunable {
            guard isInside(real(worktree.path), real(path)) else { return blocked(.worktreeElsewhere(abbreviate(worktree.path))) }
            inside.append(path + real(worktree.path).dropFirst(real(path).count))
        }
        let checkouts = [path] + inside

        for checkout in checkouts {
            let status = await git(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none"], in: checkout)
            guard status.succeeded else { return blocked(.checkFailed(String(localized: "for uncommitted changes"))) }
            let changed = parseStatus(status.stdout).filter { entry in
                let full = checkout + "/" + entry.trimmingSuffix("/")
                return (entry as NSString).lastPathComponent != ".DS_Store" && !inside.contains(full)
            }
            if let first = changed.first {
                return blocked(.uncommitted(files: changed.count, example: relative(checkout + "/" + first, to: path)))
            }
        }

        let stashes = await git(["stash", "list"], in: path)
        guard stashes.succeeded else { return blocked(.checkFailed(String(localized: "the stash"))) }
        let stashCount = lines(stashes.stdout).count
        if stashCount > 0 { return blocked(.stashed(stashCount)) }

        let refs = await git(["for-each-ref", "--format=%(refname:short)%00%(upstream)%00%(upstream:track,nobracket)%00%(upstream:remotename)", "refs/heads"], in: path)
        guard refs.succeeded else { return blocked(.checkFailed(String(localized: "the branches"))) }
        let branches = parseBranches(refs.stdout)
        guard !branches.isEmpty else { return blocked(.noBranch) }
        for branch in branches {
            guard let remote = branch.remote, remote != "." else { return blocked(.noUpstream(branch.name)) }
            if branch.track.contains("gone") { return blocked(.upstreamGone(branch.name)) }
            if let ahead = aheadCount(branch.track), ahead > 0 { return blocked(.ahead(branch: branch.name, commits: ahead)) }
        }

        let unpushed = await git(["rev-list", "--count", "--branches", "--not", "--remotes"], in: path)
        guard unpushed.succeeded else { return blocked(.checkFailed(String(localized: "for unpushed commits"))) }
        let unpushedCount = Int(unpushed.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if unpushedCount > 0 { return blocked(.unpushed(unpushedCount)) }

        if let problem = await submoduleProblem(in: path) { return blocked(problem) }

        var ignored: [String] = []
        for checkout in checkouts {
            guard let found = await ignoredWork(in: checkout, worktrees: inside) else {
                return blocked(.checkFailed(String(localized: "the ignored files")))
            }
            ignored += found.map { item in
                var isFolder: ObjCBool = false
                let folder = FileManager.default.fileExists(atPath: item, isDirectory: &isFolder) && isFolder.boolValue
                return relative(item, to: path) + (folder ? "/" : "")
            }
        }
        if !ignored.isEmpty { return blocked(.ignoredFiles(ignored.sorted())) }

        var idle = context
        idle.activityWindow = idleWindow
        let verdict = await CleanupScanner.projectVerdict(path, buildFolders: [], context: idle)
        repo.lastActivity = verdict.lastActivity
        if let reason = verdict.blocked { return blocked(.notIdle(reason)) }

        return await remoteVerdict(repo, branches: branches, worktrees: worktrees, github: github)
    }

    /// Asks each remote what it has right now, so a branch deleted on GitHub after a merge
    /// can't pass on a stale remote-tracking branch.
    private static func remoteVerdict(_ repo: LocalRepo, branches: [Branch], worktrees: [Worktree], github: GitHubCheck) async -> LocalRepo {
        var repo = repo
        func blocked(_ problem: RepoProblem) -> LocalRepo {
            var result = repo
            result.blocked = problem
            return result
        }
        let path = repo.path
        let current = await git(["symbolic-ref", "-q", "--short", "HEAD"], in: path).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = Set(branches.compactMap(\.remote))
        let primary = branches.first { $0.name == current }?.remote ?? names.sorted().first

        var advertised: [String: Set<String>] = [:]
        for name in names.sorted() {
            let url = await git(["ls-remote", "--get-url", name], in: path).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty, let slug = await github.slug(url) else { return blocked(.notGitHub(url.isEmpty ? name : url)) }
            if name == primary { repo.remote = RepoRemote(name: name, url: url, slug: slug) }
            let listing = await git(["ls-remote", name], in: path, timeout: .seconds(45), network: true)
            guard listing.succeeded else { return blocked(.remoteUnreachable(name)) }
            for line in lines(listing.stdout) {
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[1].hasPrefix("refs/heads/") || parts[1].hasPrefix("refs/tags/") else { continue }
                advertised[parts[1], default: []].insert(parts[0])
            }
            switch await github.status(slug) {
            case .archived: return blocked(.archived(slug))
            case .missing: return blocked(.missingOnGitHub(slug))
            case .failed: return blocked(.gitHubUnknown(slug))
            case .active, .unchecked: break
            }
        }

        let tags = await git(["for-each-ref", "--format=%(objectname)%00%(refname)", "refs/tags"], in: path)
        guard tags.succeeded else { return blocked(.checkFailed(String(localized: "the tags"))) }
        for line in lines(tags.stdout) {
            let parts = line.split(separator: "\0").map(String.init)
            guard parts.count == 2 else { continue }
            if advertised[parts[1]]?.contains(parts[0]) != true {
                return blocked(.tagNotOnRemote(String(parts[1].dropFirst("refs/tags/".count))))
            }
        }

        // Every commit on a branch, at HEAD or at a worktree's HEAD must be reachable from
        // something the remote has right now. Commits this copy hasn't fetched are skipped
        // by --ignore-missing, which can only make the answer stricter.
        let tips = Set(advertised.values.flatMap { $0 })
        let heads = worktrees.compactMap(\.head)
        let count = await git(["rev-list", "--count", "--ignore-missing", "--branches", "HEAD"] + heads + ["--not"] + tips.sorted(), in: path)
        guard count.succeeded, let missing = Int(count.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return blocked(.checkFailed(String(localized: "which commits are on GitHub")))
        }
        if missing > 0 { return blocked(.notOnRemote(missing)) }
        return repo
    }

    /// Submodules move with the repository, so their own commits and stashes must be on
    /// their remotes too. Changed files in them already show in the parent's status.
    private static func submoduleProblem(in path: String) async -> RepoProblem? {
        guard FileManager.default.fileExists(atPath: path + "/.gitmodules") else { return nil }
        let listing = await git(["submodule", "foreach", "--quiet", "--recursive", "pwd"], in: path)
        guard listing.succeeded else { return .checkFailed(String(localized: "the submodules")) }
        for submodule in lines(listing.stdout) {
            let name = relative(PathGuard.normalized(submodule), to: path)
            let stashes = await git(["stash", "list"], in: submodule)
            let unpushed = await git(["rev-list", "--count", "HEAD", "--branches", "--not", "--remotes"], in: submodule)
            guard stashes.succeeded, unpushed.succeeded else { return .checkFailed(String(localized: "the submodules")) }
            if !lines(stashes.stdout).isEmpty || (Int(unpushed.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1) > 0 {
                return .submoduleChanged(name)
            }
        }
        return nil
    }

    /// Ignored files and folders in one checkout that a fresh clone wouldn't bring back:
    /// anything but build output the scanner knows and disposable caches. Nil if git failed.
    private static func ignoredWork(in checkout: String, worktrees: [String]) async -> [String]? {
        let output = await git(["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"], in: checkout)
        guard output.succeeded else { return nil }
        var result: [String] = []
        for entry in output.stdout.split(separator: "\0").map(String.init) {
            let full = checkout + "/" + entry.trimmingSuffix("/")
            result += unrebuildable(full, root: checkout, worktrees: worktrees)
        }
        // git may list a folder and a folder inside it; the outer one says it all.
        return Repositories.outermost(result)
    }

    /// `path` if losing it loses work. An ignored folder that holds a worktree (like
    /// .worktrees/) is opened up, since the worktree is checked on its own.
    static func unrebuildable(_ path: String, root: String, worktrees: [String]) -> [String] {
        if worktrees.contains(path) { return [] }
        if worktrees.contains(where: { $0.hasPrefix(path + "/") }) {
            return CleanupScanner.children(of: URL(fileURLWithPath: path))
                .flatMap { unrebuildable(PathGuard.normalized($0.path), root: root, worktrees: worktrees) }
        }
        return holdsWork(path, root: root) ? [path] : []
    }

    /// git lists a folder whose files are all ignored as one entry, even when they are
    /// only caches, so a folder counts as work only if something in it isn't rebuildable.
    /// Stops at the first such file.
    private static func holdsWork(_ path: String, root: String) -> Bool {
        if isRebuildable(path, root: root) { return false }
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else { return true }
        return CleanupScanner.children(of: url).contains { holdsWork(PathGuard.normalized($0.path), root: root) }
    }

    /// True when `path` is, or is inside, a build folder the scanner recognises (with its
    /// manifest, so an ignored `target` folder in a non-Rust project still counts as work),
    /// or a disposable cache.
    static func isRebuildable(_ path: String, root: String) -> Bool {
        var current = path
        while current.hasPrefix(root + "/") {
            let url = URL(fileURLWithPath: current)
            if disposableNames.contains(url.lastPathComponent) { return true }
            if CleanupScanner.buildFolderRules.contains(where: { $0.matches(url) }) { return true }
            current = (current as NSString).deletingLastPathComponent
        }
        return false
    }

    // MARK: GitHub

    /// owner/name when `url` points at github.com, directly or through a host alias in
    /// ~/.ssh/config.
    static func gitHubSlug(for url: String) async -> String? {
        guard let (host, path, isSSH) = splitRemote(url) else { return nil }
        var hostname = host.lowercased()
        if isSSH, !gitHubHosts.contains(hostname) {
            let resolved = await Shell.run("/usr/bin/ssh", ["-G", host], timeout: .seconds(5))
            hostname = lines(resolved.stdout).first { $0.hasPrefix("hostname ") }.map { String($0.dropFirst(9)).lowercased() } ?? hostname
        }
        guard gitHubHosts.contains(hostname) else { return nil }
        return slug(fromPath: path)
    }

    static let gitHubHosts: Set<String> = ["github.com", "www.github.com", "ssh.github.com"]

    /// Host, path and whether ssh reads the host, for URL and scp-style remotes.
    static func splitRemote(_ url: String) -> (host: String, path: String, isSSH: Bool)? {
        if url.contains("://") {
            guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(),
                  let host = components.host, !host.isEmpty,
                  ["https", "http", "ssh", "git", "git+ssh", "ssh+git"].contains(scheme)
            else { return nil }
            return (host, components.path, scheme.contains("ssh"))
        }
        // scp style: [user@]host:owner/name.git. A path with a slash before the colon is local.
        guard let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") else { return nil }
        let host = url[..<colon].split(separator: "@").last.map(String.init) ?? ""
        guard !host.isEmpty else { return nil }
        return (host, String(url[url.index(after: colon)...]), true)
    }

    static func slug(fromPath path: String) -> String? {
        var parts = path.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[1].hasSuffix(".git") { parts[1].removeLast(4) }
        guard !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return parts.joined(separator: "/")
    }

    static func gitHubStatus(of slug: String) async -> GitHubStatus {
        guard Shell.which("gh") != nil else { return .unchecked }
        let output = await Shell.run("gh", ["repo", "view", slug, "--json", "isArchived"], timeout: .seconds(30),
                                     environment: ["GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1"])
        if output.succeeded {
            struct View: Decodable { let isArchived: Bool }
            guard let view = try? JSONDecoder().decode(View.self, from: Data(output.stdout.utf8)) else { return .failed }
            return view.isArchived ? .archived : .active
        }
        if output.stderr.contains("Could not resolve to a Repository") { return .missing }
        if output.stderr.contains("gh auth login") { return .unchecked }
        return .failed
    }

    // MARK: Moving and cloning

    /// Moves each repository to the Bin after running every check again with fresh data.
    /// Returns nil when another clean-up holds the lock and nothing was done. `trash` is
    /// swapped out by tests so they never fill the real Bin.
    static func moveToBin(
        _ repos: [LocalRepo],
        idleWindow: TimeInterval,
        projectRoots: [URL],
        github: GitHubCheck = .live,
        references: ExternalReferences? = nil,
        trash: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) async -> CleanupRun? {
        let started = Date.now
        let freeBefore = SystemProbe.disk().available
        guard let lock = CleanupLock.acquire() else { return nil }
        defer { CleanupLock.release(lock) }

        let context = await ScanContext.capture(activityWindow: idleWindow, projectRoots: projectRoots, measureSizes: false,
                                                references: references)
        var records: [RepoRecord] = []
        var done = Set<String>()
        for repo in repos where done.insert(repo.path).inserted {
            let result: CleanupOutcome.Result
            if !FileManager.default.fileExists(atPath: repo.path) {
                result = .skipped(String(localized: "No longer exists"))
            } else {
                let current = await inspect(repo.path, context: context, idleWindow: idleWindow, github: github)
                if let problem = current.blocked {
                    result = .skipped(problem.description)
                } else if current.gitInode != repo.gitInode || current.remote != repo.remote {
                    result = .skipped(String(localized: "It moved or changed since the list was made"))
                } else if let reason = await InUseSnapshot.capture().blockReason(under: repo.path) {
                    // The checks above can take a while; a process may have started meanwhile.
                    result = .skipped(reason.description)
                } else {
                    result = trashRepository(URL(fileURLWithPath: repo.path), trash: trash)
                }
            }
            records.append(RepoRecord(path: repo.path, remoteURL: repo.remote?.url ?? "", slug: repo.remote?.slug,
                                      bytes: repo.bytes, result: result))
        }
        return CleanupRun(id: UUID(), startedAt: started, finishedAt: .now, trigger: .manual, freeBefore: freeBefore,
                          freeAfter: SystemProbe.disk().available, outcomes: [], repositories: records)
    }

    private static func trashRepository(_ url: URL, trash: (URL) throws -> Void) -> CleanupOutcome.Result {
        do {
            try PathGuard.validateForDeletion(url)
            try trash(url)
            return .removed
        } catch let violation as PathGuard.Violation {
            return .skipped(violation.description)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Clones a repository from History back to where it was. Returns a problem, or nil.
    /// Uses gh when there is a GitHub name and gh is installed, git otherwise.
    static func clone(_ record: RepoRecord, preferGH: Bool = true) async -> String? {
        guard !FileManager.default.fileExists(atPath: record.path) else {
            return String(localized: "Something is already at \(abbreviate(record.path))")
        }
        guard !record.remoteURL.isEmpty || record.slug != nil else { return String(localized: "History has no remote for this repository") }
        let parent = (record.path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        } catch {
            return error.localizedDescription
        }
        let environment = ["GIT_TERMINAL_PROMPT": "0", "GH_PROMPT_DISABLED": "1"]
        let output = if preferGH, let slug = record.slug, Shell.which("gh") != nil {
            await Shell.run("gh", ["repo", "clone", slug, record.path], timeout: .seconds(1800), environment: environment)
        } else {
            await Shell.run("/usr/bin/git", ["clone", "--", record.remoteURL, record.path], timeout: .seconds(1800), environment: environment)
        }
        if output.succeeded { return nil }
        let message = (output.stderr.nonEmpty ?? output.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        return output.timedOut ? String(localized: "The clone took too long and was stopped") : String(message.suffix(300))
    }

    // MARK: Git plumbing

    /// Read-only git: no optional locks (git status would otherwise refresh the index), no
    /// prompts for passwords or host keys, and ssh never waits for input.
    private static func git(_ arguments: [String], in folder: String, timeout: Duration = .seconds(60), network: Bool = false) async -> Shell.Output {
        var environment = ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"]
        if network, ProcessInfo.processInfo.environment["GIT_SSH_COMMAND"] == nil {
            let configured = await Shell.run("/usr/bin/git", ["-C", folder, "config", "--get", "core.sshCommand"], timeout: .seconds(10))
            if configured.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
            }
        }
        return await Shell.run("/usr/bin/git", ["-C", folder] + arguments, timeout: timeout, environment: environment)
    }

    struct Worktree: Sendable {
        var path: String
        var head: String?
        var prunable = false
    }

    static func parseWorktrees(_ text: String) -> [Worktree] {
        var result: [Worktree] = []
        for field in text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init) {
            if field.hasPrefix("worktree ") {
                result.append(Worktree(path: String(field.dropFirst(9))))
            } else if field.hasPrefix("HEAD "), !result.isEmpty {
                result[result.count - 1].head = String(field.dropFirst(5))
            } else if field.hasPrefix("prunable"), !result.isEmpty {
                result[result.count - 1].prunable = true
            }
        }
        return result
    }

    /// Paths from `git status --porcelain -z`. A rename carries its old path as an extra field.
    static func parseStatus(_ text: String) -> [String] {
        var result: [String] = []
        var fields = text.split(separator: "\0").map(String.init)[...]
        while let field = fields.popFirst() {
            guard field.count > 3 else { continue }
            let code = field.prefix(2)
            result.append(String(field.dropFirst(3)))
            if code.contains("R") || code.contains("C") { _ = fields.popFirst() }
        }
        return result
    }

    struct Branch: Sendable {
        let name: String
        let remote: String?
        let track: String
    }

    static func parseBranches(_ text: String) -> [Branch] {
        lines(text).compactMap { line in
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, !parts[0].isEmpty else { return nil }
            return Branch(name: parts[0], remote: parts[1].isEmpty || parts[3].isEmpty ? nil : parts[3], track: parts[2])
        }
    }

    /// "ahead 2, behind 1" → 2.
    static func aheadCount(_ track: String) -> Int? {
        guard let range = track.range(of: "ahead ") else { return nil }
        return Int(track[range.upperBound...].prefix { $0.isNumber })
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private static func real(_ path: String) -> String {
        PathGuard.normalized(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }

    private static func isInside(_ path: String, _ folder: String) -> Bool {
        path.lowercased().hasPrefix(folder.lowercased() + "/")
    }

    private static func relative(_ path: String, to root: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : abbreviate(path)
    }

    private static func inode(_ path: String) -> UInt64 {
        var info = stat()
        return lstat(path, &info) == 0 ? UInt64(info.st_ino) : 0
    }

    static func abbreviate(_ path: String) -> String {
        path.hasPrefix(PathGuard.home + "/") ? "~" + path.dropFirst(PathGuard.home.count) : path
    }

    /// The first few names and how many more, in the user's language.
    static func list(_ names: [String], showing limit: Int = 4) -> String {
        let more = names.count - limit
        guard more > 0 else { return names.formatted(.list(type: .and)) }
        let first = names.prefix(limit).joined(separator: ", ")
        return String(localized: "\(first) and \(more) more")
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
