import Foundation
import Testing
@testable import MacUnclog

/// Builds real repositories with a local bare repository standing in for GitHub, and
/// checks that each "nothing exists only here" rule keeps a repository off the list.
@Suite(.serialized)
struct RepositoryTests {
    let base: URL
    let projects: URL
    let remotes: URL
    let longAgo = Date(timeIntervalSinceNow: -90 * 86_400)
    let idleWindow: TimeInterval = 60 * 86_400

    init() throws {
        base = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/MacUnclogTests-\(UUID().uuidString)")
        projects = base.appendingPathComponent("projects")
        remotes = base.appendingPathComponent("remotes")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remotes, withIntermediateDirectories: true)
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: Helpers

    @discardableResult
    private func git(_ arguments: [String], in folder: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder.path, "-c", "protocol.file.allow=always", "-c", "init.defaultBranch=main"] + arguments
        var environment = ProcessInfo.processInfo.environment
        let stamp = "\(Int(longAgo.timeIntervalSince1970)) +0000"
        environment["GIT_AUTHOR_DATE"] = stamp
        environment["GIT_COMMITTER_DATE"] = stamp
        environment["GIT_AUTHOR_NAME"] = "Test"
        environment["GIT_AUTHOR_EMAIL"] = "test@example.invalid"
        environment["GIT_COMMITTER_NAME"] = "Test"
        environment["GIT_COMMITTER_EMAIL"] = "test@example.invalid"
        // The user's global gitignore and hooks would change what these tests see.
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitFailure(arguments: arguments, status: process.terminationStatus)
        }
        return String(decoding: data, as: UTF8.self)
    }

    struct GitFailure: Error {
        let arguments: [String]
        let status: Int32
    }

    private func write(_ text: String, to relative: String, in folder: URL) throws {
        let url = folder.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A pushed repository with a bare "GitHub" remote, every file dated three months back.
    @discardableResult
    private func makeRepo(_ name: String, ignore: String = "node_modules/\n.worktrees/\n") throws -> URL {
        let remote = remotes.appendingPathComponent("\(name).git")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try git(["init", "-q", "--bare"], in: remote)
        let repo = projects.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q"], in: repo)
        try write("{}", to: "package.json", in: repo)
        try write(ignore, to: ".gitignore", in: repo)
        try git(["add", "-A"], in: repo)
        try git(["commit", "-q", "-m", "init"], in: repo)
        try git(["remote", "add", "origin", remote.path], in: repo)
        try git(["push", "-q", "-u", "origin", "main"], in: repo)
        try age(repo)
        return repo
    }

    private func age(_ folder: URL) throws {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            try? FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: url.path)
        }
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: folder.path)
    }

    /// Bare repositories under `remotes` play GitHub; anything else isn't on GitHub.
    private func github(_ status: GitHubStatus = .active) -> GitHubCheck {
        let remotes = remotes.path
        return GitHubCheck(
            slug: { url in
                guard url.hasPrefix(remotes + "/"), url.hasSuffix(".git") else { return nil }
                return "test/" + ((url as NSString).lastPathComponent as NSString).deletingPathExtension
            },
            status: { _ in status }
        )
    }

    private func context(inUse: InUseSnapshot = InUseSnapshot(entries: []), external: ExternalReferences = .empty) -> ScanContext {
        ScanContext(inUse: inUse, simulators: .empty, activityWindow: 3 * 86_400, projectRoots: [projects],
                    external: external, measureSizes: false)
    }

    private func inspect(_ repo: URL, github: GitHubCheck? = nil, context: ScanContext? = nil) async -> LocalRepo {
        await Repositories.inspect(repo.path, context: context ?? self.context(), idleWindow: idleWindow, github: github ?? self.github())
    }

    // MARK: Offered

    @Test func pushedIdleRepositoryIsOfferedWithItsRemote() async throws {
        defer { cleanup() }
        let repo = try makeRepo("done")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("node_modules/left-pad"), withIntermediateDirectories: true)
        try write("module.exports = 1", to: "node_modules/left-pad/index.js", in: repo)
        try git(["tag", "v1"], in: repo)
        try git(["push", "-q", "origin", "v1"], in: repo)
        try age(repo)

        var scan = context()
        scan.measureSizes = true
        let found = await Repositories.find(in: scan, idleWindow: idleWindow, github: github())
        let listed = try #require(found.first { $0.path == repo.path })
        #expect(listed.blocked == nil)
        #expect(listed.remote?.slug == "test/done")
        #expect(listed.bytes > 0)
        #expect(listed.lastActivity.map { abs($0.timeIntervalSince(longAgo)) < 5 } == true)
    }

    @Test func aRepositoryInsideAnotherIsNotListedOnItsOwn() async throws {
        defer { cleanup() }
        let outer = try makeRepo("outer", ignore: "vendor/\n")
        let inner = outer.appendingPathComponent("vendor/inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try git(["init", "-q"], in: inner)
        let found = await Repositories.find(in: context(), idleWindow: idleWindow, github: github())
        #expect(found.map(\.path) == [outer.path])
        #expect(found.first?.blocked == .ignoredFiles(["vendor/"]))
    }

    // MARK: Local work

    @Test func changedOrUntrackedFilesKeepIt() async throws {
        defer { cleanup() }
        let repo = try makeRepo("dirty")
        try write("{\"name\":\"x\"}", to: "package.json", in: repo)
        #expect(await inspect(repo).blocked == .uncommitted(files: 1, example: "package.json"))

        try git(["checkout", "--", "package.json"], in: repo)
        try write("notes", to: "notes/todo.md", in: repo)
        #expect(await inspect(repo).blocked == .uncommitted(files: 1, example: "notes/todo.md"))
    }

    @Test func aStashKeepsIt() async throws {
        defer { cleanup() }
        let repo = try makeRepo("stashed")
        try write("{\"wip\":true}", to: "package.json", in: repo)
        try git(["stash", "-q"], in: repo)
        try age(repo)
        #expect(await inspect(repo).blocked == .stashed(1))
    }

    @Test func aRepositoryWithoutCommitsKeepsIt() async throws {
        defer { cleanup() }
        let repo = projects.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q"], in: repo)
        #expect(await inspect(repo).blocked == .noBranch)
    }

    @Test func aBranchWithoutUpstreamKeepsIt() async throws {
        defer { cleanup() }
        let repo = try makeRepo("local-branch")
        try git(["branch", "experiment"], in: repo)
        #expect(await inspect(repo).blocked == .noUpstream("experiment"))
    }

    @Test func unpushedCommitsKeepIt() async throws {
        defer { cleanup() }
        let repo = try makeRepo("ahead")
        try write("a", to: "a.txt", in: repo)
        try git(["add", "a.txt"], in: repo)
        try git(["commit", "-q", "-m", "local"], in: repo)
        try age(repo)
        #expect(await inspect(repo).blocked == .ahead(branch: "main", commits: 1))
    }

    @Test func aBranchWhoseRemoteBranchIsGoneKeepsIt() async throws {
        defer { cleanup() }
        let repo = try makeRepo("gone")
        try git(["switch", "-q", "-c", "feature"], in: repo)
        try git(["push", "-q", "-u", "origin", "feature"], in: repo)
        try git(["push", "-q", "origin", "--delete", "feature"], in: repo)
        #expect(await inspect(repo).blocked == .upstreamGone("feature"))
    }

    @Test func aTagThatOnlyExistsHereKeepsIt() async throws {
        defer { cleanup() }
        let repo = try makeRepo("tagged")
        try git(["tag", "release-1"], in: repo)
        #expect(await inspect(repo).blocked == .tagNotOnRemote("release-1"))
    }

    @Test func aTagThatPointsElsewhereOnTheRemoteKeepsIt() async throws {
        defer { cleanup() }
        let repo = try makeRepo("moved-tag")
        try git(["tag", "-a", "v1", "-m", "first"], in: repo)
        try git(["push", "-q", "origin", "v1"], in: repo)
        try git(["tag", "-f", "-a", "v1", "-m", "rewritten"], in: repo)
        #expect(await inspect(repo).blocked == .tagNotOnRemote("v1"))
    }

    // MARK: Worktrees and submodules

    @Test func aWorktreeInsideIsCheckedAndMovesAlong() async throws {
        defer { cleanup() }
        let repo = try makeRepo("with-worktree")
        try git(["worktree", "add", "-q", "--track", "-b", "review", ".worktrees/review", "origin/main"], in: repo)
        try age(repo)
        #expect(await inspect(repo).blocked == nil)

        try write("draft", to: ".worktrees/review/draft.md", in: repo)
        #expect(await inspect(repo).blocked == .uncommitted(files: 1, example: ".worktrees/review/draft.md"))
    }

    @Test func aWorktreeOutsideTheFolderKeepsIt() async throws {
        defer { cleanup() }
        let repo = try makeRepo("split")
        let elsewhere = projects.appendingPathComponent("split-review")
        try git(["worktree", "add", "-q", "--track", "-b", "review", elsewhere.path, "origin/main"], in: repo)
        try age(repo)
        guard case .worktreeElsewhere = await inspect(repo).blocked else {
            Issue.record("Expected worktreeElsewhere")
            return
        }
    }

    @Test func aSubmoduleCommitThatOnlyExistsHereKeepsIt() async throws {
        defer { cleanup() }
        try makeRepo("library")
        let repo = try makeRepo("app")
        try git(["submodule", "add", "-q", remotes.appendingPathComponent("library.git").path, "lib"], in: repo)
        try git(["commit", "-q", "-m", "add lib"], in: repo)
        try git(["push", "-q"], in: repo)
        try age(repo)
        #expect(await inspect(repo).blocked == nil)

        let submodule = repo.appendingPathComponent("lib")
        try git(["switch", "-q", "main"], in: submodule)
        try write("x", to: "x.txt", in: submodule)
        try git(["add", "x.txt"], in: submodule)
        try git(["commit", "-q", "-m", "only here"], in: submodule)
        try git(["commit", "-q", "-am", "bump lib"], in: repo)
        try git(["push", "-q"], in: repo)
        try age(repo)
        #expect(await inspect(repo).blocked == .submoduleChanged("lib"))
    }

    // MARK: The remote

    @Test func aRemoteThatIsNotGitHubKeepsIt() async throws {
        defer { cleanup() }
        let repo = try makeRepo("elsewhere")
        let nowhere = GitHubCheck(slug: { _ in nil }, status: { _ in .active })
        guard case .notGitHub = await inspect(repo, github: nowhere).blocked else {
            Issue.record("Expected notGitHub")
            return
        }
    }

    @Test func anUnreachableRemoteKeepsIt() async throws {
        defer { cleanup() }
        let repo = try makeRepo("offline")
        try FileManager.default.removeItem(at: remotes.appendingPathComponent("offline.git"))
        try FileManager.default.createDirectory(at: remotes.appendingPathComponent("offline.git"), withIntermediateDirectories: true)
        #expect(await inspect(repo).blocked == .remoteUnreachable("origin"))
    }

    @Test func anArchivedOrMissingGitHubRepositoryKeepsIt() async throws {
        defer { cleanup() }
        let repo = try makeRepo("old")
        #expect(await inspect(repo, github: github(.archived)).blocked == .archived("test/old"))
        #expect(await inspect(repo, github: github(.missing)).blocked == .missingOnGitHub("test/old"))
        #expect(await inspect(repo, github: github(.failed)).blocked == .gitHubUnknown("test/old"))
        #expect(await inspect(repo, github: github(.unchecked)).blocked == nil)
    }

    @Test func aBranchDeletedOnGitHubAfterTheLastFetchKeepsIt() async throws {
        defer { cleanup() }
        let repo = try makeRepo("squashed")
        try git(["switch", "-q", "-c", "feature"], in: repo)
        try write("f", to: "f.txt", in: repo)
        try git(["add", "f.txt"], in: repo)
        try git(["commit", "-q", "-m", "feature"], in: repo)
        try git(["push", "-q", "-u", "origin", "feature"], in: repo)
        // Deleted on "GitHub" directly, so this copy's origin/feature is now stale.
        try git(["branch", "-D", "feature"], in: remotes.appendingPathComponent("squashed.git"))
        try git(["switch", "-q", "main"], in: repo)
        try age(repo)
        #expect(await inspect(repo).blocked == .notOnRemote(1))
    }

    // MARK: Idle

    @Test func aRecentlyChangedRepositoryStays() async throws {
        defer { cleanup() }
        let repo = try makeRepo("fresh")
        try write("hello", to: "node_modules/.package-lock.json", in: repo)
        guard case .notIdle(.recentlyModified) = await inspect(repo).blocked else {
            Issue.record("Expected recentlyModified")
            return
        }
    }

    @Test func aRepositoryInUseStays() async throws {
        defer { cleanup() }
        let repo = try makeRepo("served")
        let shell = InUseSnapshot(entries: [.init(path: repo.path, process: ProcessRef(pid: 4242, name: "zsh"), isWorkingDirectory: true)])
        #expect(await inspect(repo, context: context(inUse: shell)).blocked == .notIdle(.workingDirectory(ProcessRef(pid: 4242, name: "zsh"))))

        let editor = InUseSnapshot(entries: [.init(path: repo.path + "/package.json", process: ProcessRef(pid: 77, name: "Zed"), isWorkingDirectory: false)])
        #expect(await inspect(repo, context: context(inUse: editor)).blocked == .notIdle(.openFile(ProcessRef(pid: 77, name: "Zed"))))
    }

    @Test func aRepositoryUsedFromOutsideStays() async throws {
        defer { cleanup() }
        let repo = try makeRepo("mcp-server")
        let references = ExternalReferences(references: [.init(path: repo.path + "/dist/index.js", source: "~/.claude.json")])
        #expect(await inspect(repo, context: context(external: references)).blocked == .notIdle(.usedFromOutside("~/.claude.json")))
    }

    // MARK: Ignored files

    @Test func ignoredFilesThatAreNotBuildOutputKeepItAndAreNamed() async throws {
        defer { cleanup() }
        let repo = try makeRepo("secrets", ignore: "node_modules/\n.env\n*.sqlite\ntarget/\n.DS_Store\n__pycache__/\n")
        try write("module.exports = 1", to: "node_modules/a/index.js", in: repo)
        try write("", to: ".DS_Store", in: repo)
        try write("", to: "tools/__pycache__/x.pyc", in: repo)
        try git(["add", "-A"], in: repo)
        try age(repo)
        #expect(await inspect(repo).blocked == nil)

        try write("TOKEN=1", to: ".env", in: repo)
        try write("", to: "data/local.sqlite", in: repo)
        try write("", to: "data/__pycache__/cache.pyc", in: repo)
        // A target folder without Cargo.toml isn't Rust build output.
        try write("notes", to: "target/notes.txt", in: repo)
        try age(repo)
        #expect(await inspect(repo).blocked == .ignoredFiles([".env", "data/", "target/"]))
    }

    // MARK: Moving and cloning

    @Test func moveRechecksAndRecordsWhatItTakesToCloneAgain() async throws {
        defer { cleanup() }
        let keep = try makeRepo("wakes-up")
        let go = try makeRepo("finished")
        let listed = [await inspect(keep), await inspect(go)]
        #expect(listed.allSatisfy { $0.canMove })

        try write("new", to: "index.ts", in: keep)
        let bin = base.appendingPathComponent("Bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let run = try #require(await Repositories.moveToBin(listed, idleWindow: idleWindow, projectRoots: [projects],
                                                            github: github(), references: .empty, trash: { url in
            try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(url.lastPathComponent))
        }))
        let records = try #require(run.repositories)
        #expect(run.outcomes.isEmpty)
        #expect(records.first { $0.path == keep.path }?.result == .skipped(RepoProblem.uncommitted(files: 1, example: "index.ts").description))
        let moved = try #require(records.first { $0.path == go.path })
        #expect(moved.result == .removed)
        #expect(moved.remoteURL == remotes.appendingPathComponent("finished.git").path)
        #expect(moved.slug == "test/finished")
        #expect(FileManager.default.fileExists(atPath: keep.path))
        #expect(!FileManager.default.fileExists(atPath: go.path))

        // History keeps the record; Clone again brings it back to the same place.
        let roundTrip = try JSONDecoder().decode([RepoRecord].self, from: JSONEncoder().encode(records))
        #expect(roundTrip == records)
        #expect(await Repositories.clone(moved, preferGH: false) == nil)
        #expect(FileManager.default.fileExists(atPath: go.appendingPathComponent("package.json").path))
        #expect(await Repositories.clone(moved, preferGH: false) != nil)
    }

    @Test func moveSkipsARepositoryReplacedAtTheSamePath() async throws {
        defer { cleanup() }
        let repo = try makeRepo("replaced")
        let listed = await inspect(repo)
        #expect(listed.canMove)
        // A fresh clone of the same remote passes every check but is not the copy that was listed.
        try FileManager.default.removeItem(at: repo)
        try git(["clone", "-q", remotes.appendingPathComponent("replaced.git").path, repo.path], in: projects)
        try age(repo)
        #expect(await inspect(repo).canMove)
        let run = try #require(await Repositories.moveToBin([listed], idleWindow: idleWindow, projectRoots: [projects],
                                                            github: github(), references: .empty, trash: { _ in
            Issue.record("Nothing should be moved")
        }))
        #expect(run.repositories?.first?.result == .skipped(String(localized: "It moved or changed since the list was made")))
    }

    // MARK: Remote URLs

    @Test func gitHubRemotesAreRecognised() async {
        #expect(await Repositories.gitHubSlug(for: "https://github.com/owner/name.git") == "owner/name")
        #expect(await Repositories.gitHubSlug(for: "https://user@github.com/owner/name") == "owner/name")
        #expect(await Repositories.gitHubSlug(for: "git@github.com:owner/name.git") == "owner/name")
        #expect(await Repositories.gitHubSlug(for: "ssh://git@github.com/owner/name.git") == "owner/name")
        #expect(await Repositories.gitHubSlug(for: "https://gitlab.com/owner/name.git") == nil)
        #expect(await Repositories.gitHubSlug(for: "https://github.com/owner/name/extra") == nil)
        #expect(await Repositories.gitHubSlug(for: "/Users/me/remotes/name.git") == nil)
        #expect(await Repositories.gitHubSlug(for: "../name.git") == nil)
    }
}
