import Foundation
import Testing
@testable import MacUnclog

/// Builds real git projects on disk and runs the scanner and executor against them.
@Suite(.serialized)
struct ProjectBuildTests {
    let root: URL
    let longAgo = Date(timeIntervalSinceNow: -30 * 86_400)

    init() throws {
        root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/MacUnclogTests-\(UUID().uuidString)/projects")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func git(_ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        let stamp = "\(Int(longAgo.timeIntervalSince1970)) +0000"
        environment["GIT_AUTHOR_DATE"] = stamp
        environment["GIT_COMMITTER_DATE"] = stamp
        environment["GIT_AUTHOR_NAME"] = "Test"
        environment["GIT_AUTHOR_EMAIL"] = "test@example.invalid"
        environment["GIT_COMMITTER_NAME"] = "Test"
        environment["GIT_COMMITTER_EMAIL"] = "test@example.invalid"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    /// A node project with a 1 MB node_modules, everything dated a month back.
    @discardableResult
    private func makeProject(_ name: String, ignoreNodeModules: Bool = true) throws -> URL {
        let project = root.appendingPathComponent(name)
        let modules = project.appendingPathComponent("node_modules/left-pad")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
        try Data(count: 1_000_000).write(to: modules.appendingPathComponent("index.js"))
        try Data((ignoreNodeModules ? "node_modules/\n" : "dist/\n").utf8).write(to: project.appendingPathComponent(".gitignore"))
        try git(["init", "-q"], in: project)
        try git(["add", "package.json", ".gitignore"], in: project)
        try git(["commit", "-q", "-m", "init"], in: project)
        try age(project)
        return project
    }

    private func age(_ folder: URL) throws {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            try? FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: url.path)
        }
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: folder.path)
    }

    private func scan(inUse: InUseSnapshot = InUseSnapshot(entries: [])) async -> [CleanupItem] {
        let context = ScanContext(inUse: inUse, simulators: .empty, activityWindow: 3 * 86_400, projectRoots: [root])
        return await CleanupScanner.discover(.projectBuilds, in: context)
    }

    private func cleanup() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    // Lives in this serialised suite: the other tests here take the same lock.
    @Test func onlyOneCleanupRunsAtATime() throws {
        defer { cleanup() }
        let first = try #require(CleanupLock.acquire())
        defer { CleanupLock.release(first) }
        // flock locks belong to the open file, so a second open in this process is refused too.
        #expect(CleanupLock.acquire() == nil)
    }

    @Test func staleIgnoredNodeModulesIsOfferedAndDeleted() async throws {
        defer { cleanup() }
        let project = try makeProject("stale")
        let items = await scan()
        let item = try #require(items.first { $0.location == project.appendingPathComponent("node_modules").path })
        #expect(item.blocked == nil)
        #expect(item.bytes >= 1_000_000)

        let run = try #require(await CleanupExecutor.run([item], trigger: .manual, activityWindow: 3 * 86_400, projectRoots: [root], references: .empty))
        #expect(run.outcomes.first?.result == .removed)
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("node_modules").path))
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("package.json").path))
    }

    @Test func recentlyEditedProjectIsLeftAlone() async throws {
        defer { cleanup() }
        let project = try makeProject("active")
        try Data("changed".utf8).write(to: project.appendingPathComponent("README.md"))
        let item = try #require(await scan().first)
        guard case .recentlyModified = item.blocked else {
            Issue.record("Expected recentlyModified, got \(String(describing: item.blocked))")
            return
        }
    }

    @Test func editedSourceFolderNamedBuildCountsAsActivity() async throws {
        defer { cleanup() }
        let project = try makeProject("named-build")
        let source = project.appendingPathComponent("tools/build")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("export {}".utf8).write(to: source.appendingPathComponent("config.js"))
        let item = try #require(await scan().first)
        guard case .recentlyModified = item.blocked else {
            Issue.record("Expected recentlyModified, got \(String(describing: item.blocked))")
            return
        }
    }

    @Test func worktreeLinkKeepsTheTargetAlive() async throws {
        defer { cleanup() }
        let main = try makeProject("main")
        let worktree = try makeProject("worktree")
        try FileManager.default.removeItem(at: worktree.appendingPathComponent("node_modules"))
        try FileManager.default.createSymbolicLink(at: worktree.appendingPathComponent("node_modules"),
                                                   withDestinationURL: main.appendingPathComponent("node_modules"))
        try Data("work".utf8).write(to: worktree.appendingPathComponent("App.tsx"))
        let item = try #require(await scan().first { $0.location == main.appendingPathComponent("node_modules").path })
        #expect(item.blocked == .linkedFrom("worktree"))
    }

    @Test func folderThatIsNotGitIgnoredIsLeftAlone() async throws {
        defer { cleanup() }
        try makeProject("tracked", ignoreNodeModules: false)
        #expect(try #require(await scan().first).blocked == .notGitIgnored)
    }

    @Test func projectWithARunningProcessIsLeftAlone() async throws {
        defer { cleanup() }
        let project = try makeProject("served")
        let devServer = InUseSnapshot(entries: [
            .init(path: project.path, process: ProcessRef(pid: 8091, name: "node"), isWorkingDirectory: true),
        ])
        #expect(try #require(await scan(inUse: devServer).first).blocked == .workingDirectory(ProcessRef(pid: 8091, name: "node")))
    }

    @Test func executorRechecksAndSkipsWhenTheProjectWakesUp() async throws {
        defer { cleanup() }
        let project = try makeProject("wakes")
        let item = try #require(await scan().first)
        #expect(item.blocked == nil)

        try Data("new work".utf8).write(to: project.appendingPathComponent("index.ts"))
        let run = try #require(await CleanupExecutor.run([item], trigger: .manual, activityWindow: 3 * 86_400, projectRoots: [root], references: .empty))
        guard case .skipped = run.outcomes.first?.result else {
            Issue.record("Expected the item to be skipped, got \(String(describing: run.outcomes.first?.result))")
            return
        }
        #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("node_modules").path))
    }
}
