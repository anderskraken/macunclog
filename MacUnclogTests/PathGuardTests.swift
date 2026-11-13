import Foundation
import Testing
@testable import MacUnclog

struct PathGuardTests {
    let home = NSHomeDirectory()

    @Test(arguments: [
        "Documents/report.pdf", "Desktop", "Movies/clip.mov", "Pictures", ".claude/projects/abc",
        "Library/Application Support/Claude/vm_bundles", ".codex/sessions/2026",
        "Library/Mobile Documents/com~apple~CloudDocs/x",
    ])
    func userDataIsProtected(_ relative: String) {
        #expect(PathGuard.isProtected("\(home)/\(relative)"))
        #expect(throws: PathGuard.Violation.self) { try PathGuard.validateForDeletion(URL(fileURLWithPath: "\(home)/\(relative)")) }
    }

    @Test func userProtectedFoldersAndTheirParentsAreRefused() {
        let photos = "\(home)/dev/archive/data"
        #expect(PathGuard.isProtected("\(photos)/2024/img.jpg", userFolders: [photos]))
        #expect(PathGuard.isProtected("\(home)/dev/archive", userFolders: [photos]))
        #expect(!PathGuard.isProtected("\(home)/dev/other/node_modules", userFolders: [photos]))
    }

    @Test func ancestorsOfProtectedFoldersAreRefused() {
        #expect(throws: PathGuard.Violation.self) { try PathGuard.validateForDeletion(URL(fileURLWithPath: home)) }
        #expect(throws: PathGuard.Violation.self) { try PathGuard.validateForDeletion(URL(fileURLWithPath: "\(home)/Library")) }
        #expect(throws: PathGuard.Violation.self) { try PathGuard.validateForDeletion(URL(fileURLWithPath: "\(home)/.claude")) }
    }

    @Test(arguments: ["/tmp/x", "/System/Library/Caches", "/Applications/Xcode.app", "relative/path"])
    func pathsOutsideHomeAreRefused(_ path: String) {
        #expect(throws: PathGuard.Violation.self) { try PathGuard.validateForDeletion(URL(fileURLWithPath: path)) }
    }

    @Test(arguments: ["Library/Caches/Yarn", "Library/Developer/Xcode/DerivedData/App-abc", "dev/app/node_modules"])
    func cachesAndBuildFoldersAreAllowed(_ relative: String) throws {
        try PathGuard.validateForDeletion(URL(fileURLWithPath: "\(home)/\(relative)"))
    }

    @Test func symlinkIntoProtectedFolderIsRefusedAndNothingIsDeleted() throws {
        let sandbox = URL(fileURLWithPath: "\(home)/Library/Caches/MacUnclogTests-\(UUID().uuidString)")
        let victim = URL(fileURLWithPath: "\(home)/Documents")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let link = sandbox.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)

        #expect(throws: PathGuard.Violation.self) { try SafeDeleter.removeItem(at: link) }
        #expect(FileManager.default.fileExists(atPath: victim.path))
    }

    @Test func removeContentsEmptiesButKeepsTheFolder() throws {
        let sandbox = URL(fileURLWithPath: "\(home)/Library/Caches/MacUnclogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: sandbox.appendingPathComponent("a/b/file"))
        defer { try? FileManager.default.removeItem(at: sandbox) }

        try SafeDeleter.removeContents(of: sandbox)

        #expect(FileManager.default.fileExists(atPath: sandbox.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.path).isEmpty)
    }
}

struct InUseSnapshotTests {
    let lsof = """
    p100
    cnode
    fcwd
    n/Users/me/dev/app
    f12
    n/Users/me/dev/other/server.log
    p200
    czsh
    fcwd
    n/Users/me/dev/app-old
    ftxt
    n/Users/me/dev/tool/bin/tool
    """

    @Test func workingDirectoryIsReported() {
        let snapshot = InUseSnapshot.parse(lsof)
        #expect(snapshot.blockReason(under: "/Users/me/dev/app") == .workingDirectory(ProcessRef(pid: 100, name: "node")))
    }

    @Test func openFileIsReported() {
        let snapshot = InUseSnapshot.parse(lsof)
        #expect(snapshot.blockReason(under: "/Users/me/dev/other") == .openFile(ProcessRef(pid: 100, name: "node")))
    }

    @Test func siblingWithSharedPrefixDoesNotCount() {
        let snapshot = InUseSnapshot.parse(lsof)
        #expect(snapshot.blockReason(under: "/Users/me/dev/ap") == nil)
        #expect(snapshot.blockReason(under: "/Users/me/dev/app/node_modules") == nil)
        #expect(snapshot.blockReason(under: "/Users/me/dev/app-old") == .workingDirectory(ProcessRef(pid: 200, name: "zsh")))
    }

    @Test func runningBinaryBlocksItsFolder() {
        #expect(InUseSnapshot.parse(lsof).blockReason(under: "/Users/me/dev/tool") == .openFile(ProcessRef(pid: 200, name: "zsh")))
    }

    @Test func escapedNonASCIIPathsStillMatch() {
        let escaped = "p300\ncnode\nfcwd\nn/Users/me/dev/bj\\xc3\\xb8rn-app\n"
        #expect(InUseSnapshot.parse(escaped).blockReason(under: "/Users/me/dev/bjørn-app") == .workingDirectory(ProcessRef(pid: 300, name: "node")))
    }

    @Test func failedLsofBlocksEverything() {
        #expect(InUseSnapshot.unknown.blockReason(under: "/Users/me/anything") == .inUseUnknown)
    }
}

struct ScannerHelperTests {
    @Test func nestedProjectRootsAreScannedOnce() {
        let roots = [URL(fileURLWithPath: "/Users/me/dev"), URL(fileURLWithPath: "/Users/me/dev/kunde"), URL(fileURLWithPath: "/Users/me/dev")]
        #expect(CleanupScanner.distinctRoots(roots).map(\.path) == ["/Users/me/dev"])
    }

    @Test func findGlobCharactersAreEscaped() {
        #expect(CleanupScanner.globEscaped("/a/[x]*?") == "/a/\\[x\\]\\*\\?")
    }

    @Test func otherVolumesAreRefused() {
        #expect(PathGuard.isOnHomeVolume(NSHomeDirectory() + "/Library/Caches"))
        #expect(!PathGuard.isOnHomeVolume("/System/Volumes/Preboot"))
    }

    @Test func settingsWithMissingKeysKeepTheRest() throws {
        let stored = Data(#"{"activityWindowDays": 30, "includedCategories": ["xcode"]}"#.utf8)
        let settings = try JSONDecoder().decode(AutomationSettings.self, from: stored)
        #expect(settings.activityWindowDays == 30)
        #expect(settings.includedCategories == [.xcode])
        #expect(settings.lowDiskThresholdGB == 20)
    }
}

struct DockerSizeTests {
    @Test func parsesDockerSizes() {
        #expect(DockerSize.parse("1.5GB") == 1_500_000_000)
        #expect(DockerSize.parse("512.3MB (40%)") == 512_300_000)
        #expect(DockerSize.parse("12kB") == 12_000)
        #expect(DockerSize.parse("0B") == 0)
    }
}
