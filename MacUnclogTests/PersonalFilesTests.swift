import Foundation
import Testing
@testable import MacUnclog

@Suite(.serialized)
struct PersonalFilesTests {
    let home: URL

    init() throws {
        home = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/MacUnclogTests-\(UUID().uuidString)/home")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func file(_ relative: String, bytes: Int = 8192) throws -> String {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url.path
    }

    func inspect(_ path: String, protected: [String] = []) -> PersonalFile? {
        var cache: [String: Bool] = [:]
        return PersonalFiles.inspect(path, home: home.path, largeFileBytes: 1 << 20, userProtected: protected, gitRoots: &cache)
    }

    @Test func offersInstallersAndLargeFilesInTheUsersFolders() throws {
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        #expect(inspect(try file("Downloads/Setup.dmg"))?.kind == .installer)
        #expect(inspect(try file("Documents/Old/Tool.PKG"))?.kind == .installer)
        #expect(inspect(try file("Movies/Recording.mov", bytes: 2 << 20))?.kind == .large)
        #expect(inspect(try file("Movies/Clip.mov")) == nil)
    }

    @Test func leavesLibraryHiddenGitAndProtectedFoldersAlone() throws {
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        #expect(inspect(try file("Library/Caches/Setup.dmg")) == nil)
        #expect(inspect(try file(".docker/Setup.dmg")) == nil)
        #expect(inspect(try file("dev/app/node_modules/x/big.bin", bytes: 2 << 20)) == nil)
        _ = try file("dev/site/.git/HEAD")
        #expect(inspect(try file("dev/site/assets/video.mp4", bytes: 2 << 20)) == nil)
        #expect(inspect(try file("photospace/data/scan.tif", bytes: 2 << 20), protected: [home.path + "/photospace/data"]) == nil)
        #expect(inspect(try file("Projects/Secret/cut.mov", bytes: 2 << 20), protected: [home.path + "/projects/secret"]) == nil)
        #expect(inspect(try file("Pictures/Photos Library.photoslibrary/originals/a.heic", bytes: 2 << 20)) == nil)
    }

    @Test func aPackageMovesWholeAndALinkNotAtAll() throws {
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        let inside = try file("Documents/Notes.rtfd/TXT.rtf", bytes: 2 << 20)
        #expect(inspect(inside) == nil)
        #expect(inspect(home.appendingPathComponent("Documents/Notes.rtfd").path)?.kind == .large)

        let target = try file("Movies/Real.mov", bytes: 2 << 20)
        let link = home.appendingPathComponent("Desktop/Link.mov")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        #expect(inspect(link.path) == nil)

        let original = try file("Movies/Original.mov", bytes: 2 << 20)
        try FileManager.default.linkItem(atPath: original, toPath: home.appendingPathComponent("Movies/Hard link.mov").path)
        #expect(inspect(original) == nil)
    }

    @Test func mediaLibrariesStayWhole() throws {
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        #expect(inspect(try file("Movies/Library.fcpbundle/Media/clip.mov", bytes: 2 << 20)) == nil)
        #expect(inspect(home.appendingPathComponent("Movies/Library.fcpbundle").path) == nil)
        #expect(inspect(try file("Music/iTunes/iTunes Media/Movies/film.m4v", bytes: 2 << 20)) == nil)
        #expect(inspect(try file("Pictures/Lightroom/Catalog.lrcat", bytes: 2 << 20)) == nil)
    }
}
