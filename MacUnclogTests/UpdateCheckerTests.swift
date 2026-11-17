import Foundation
import Testing
@testable import MacUnclog

struct UpdateCheckerTests {
    func version(_ text: String) throws -> AppVersion { try #require(AppVersion(text)) }

    @Test func tagsAndBundleVersionsParse() throws {
        #expect(try version("v1.1").parts == [1, 1])
        #expect(try version("1.0.2").parts == [1, 0, 2])
        #expect(try version("V2").parts == [2])
        #expect(AppVersion("") == nil)
        #expect(AppVersion("v1.1-beta") == nil)
        #expect(AppVersion("1..2") == nil)
        #expect(AppVersion("latest") == nil)
    }

    @Test func versionsCompareByNumberNotText() throws {
        #expect(try version("v1.10") > version("1.9"))
        #expect(try version("v1.1") > version("1.0"))
        #expect(try version("v1.0.1") > version("1.0"))
        #expect(try version("v2") > version("1.99.99"))
        #expect(try version("1.0") < version("1.0.1"))
    }

    @Test func missingPartsCountAsZero() throws {
        #expect(try version("v1.1") == version("1.1.0"))
        #expect(try !(version("1.1") < version("1.1.0")))
    }

    @Test func onlyANewerReleaseIsOffered() throws {
        let release = Release(tag: "v1.1", page: URL(string: "https://github.com/anderskraken/macunclog/releases/tag/v1.1")!)
        #expect(release.isNewer(than: try version("1.0")))
        #expect(!release.isNewer(than: try version("1.1")))
        #expect(!release.isNewer(than: try version("1.2")))
        #expect(!Release(tag: "nightly", page: release.page).isNewer(than: try version("1.0")))
    }

    @Test func theLatestReleaseResponseParses() throws {
        let release = try Release.parse(Data(Self.sample.utf8))
        #expect(release.tag == "v1.1")
        #expect(release.name == "1.1")
        #expect(release.page.absoluteString == "https://github.com/anderskraken/macunclog/releases/tag/v1.1")
    }

    @Test func aReleaseOffGitHubOrWithoutAVersionIsRefused() {
        let elsewhere = Self.sample.replacingOccurrences(of: "https://github.com/", with: "https://example.com/")
        #expect(throws: UpdateError.self) { try Release.parse(Data(elsewhere.utf8)) }
        let unversioned = Self.sample.replacingOccurrences(of: #""tag_name": "v1.1""#, with: #""tag_name": "nightly""#)
        #expect(throws: UpdateError.self) { try Release.parse(Data(unversioned.utf8)) }
        #expect(throws: UpdateError.self) { try Release.parse(Data(#"{"message": "Not Found"}"#.utf8)) }
    }

    @Test func aStoredReleaseReadsBack() throws {
        let release = try Release.parse(Data(Self.sample.utf8))
        let stored = try JSONDecoder().decode(Release.self, from: JSONEncoder().encode(release))
        #expect(stored == release)
    }

    @Test func settingsSavedBeforeTheToggleExistedCheckForUpdates() throws {
        let saved = try JSONDecoder().decode(AutomationSettings.self, from: Data(#"{"lowDiskEnabled": true}"#.utf8))
        #expect(saved.checkForUpdates)
        #expect(saved.lowDiskEnabled)
    }

    /// Trimmed from a real GET /repos/{owner}/{repo}/releases/latest response.
    static let sample = """
    {
      "url": "https://api.github.com/repos/anderskraken/macunclog/releases/123456789",
      "html_url": "https://github.com/anderskraken/macunclog/releases/tag/v1.1",
      "id": 123456789,
      "tag_name": "v1.1",
      "target_commitish": "main",
      "name": "MacUnclog 1.1",
      "draft": false,
      "prerelease": false,
      "created_at": "2026-12-01T09:00:00Z",
      "published_at": "2026-12-01T09:05:00Z",
      "assets": [
        {
          "name": "MacUnclog-1.1.zip",
          "content_type": "application/zip",
          "size": 4194304,
          "browser_download_url": "https://github.com/anderskraken/macunclog/releases/download/v1.1/MacUnclog-1.1.zip"
        }
      ],
      "body": "Check for updates from the app menu."
    }
    """
}
