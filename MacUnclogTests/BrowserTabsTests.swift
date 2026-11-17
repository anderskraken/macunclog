import Foundation
import Testing
@testable import MacUnclog

struct BrowserTabsTests {
    func tab(_ window: String, _ id: String, _ url: String) -> BrowserTab {
        BrowserTab(window: window, tabID: id, index: 0, title: "", url: url)
    }

    @Test func laterCopiesOfAnAddressAreDuplicates() {
        let tabs = [tab("1", "a", "https://example.com/x"), tab("1", "b", "https://example.com/x#part"),
                    tab("2", "c", "https://example.com/x"), tab("2", "d", "https://example.com/y")]
        #expect(BrowserTabs.duplicates(in: tabs) == ["1/b", "2/c"])
    }

    @Test func blankTabsAreNotDuplicates() {
        #expect(BrowserTabs.duplicates(in: [tab("1", "a", ""), tab("1", "b", "")]).isEmpty)
    }

    @Test func anAppAnAgentSessionRunsUnderIsNeverOffered() {
        func app(_ pid: pid_t, _ name: String, _ bundleID: String) -> ProcessSample {
            ProcessSample(pid: pid, name: name, executablePath: "/Applications/\(name).app/Contents/MacOS/\(name)", bundleIdentifier: bundleID,
                          isRegularApp: true, isOwnedByUser: true, isNotResponding: false, state: .running, cpuPercent: 0, memoryBytes: 1 << 30)
        }
        let apps = [app(10, "NewTerminal", "com.example.newterminal"), app(11, "Slack", "com.tinyspeck.slackmacgap"),
                    app(12, "kitty", "net.kovidgoyal.kitty")]
        let offered = AppUsage.quittable(apps, hosts: [10]).map(\.app.name)
        #expect(offered == ["Slack"])
    }

    @Test func safariTabsAreKnownByTheirPlace() {
        let safari = BrowserTab(window: "7", tabID: "", index: 3, title: "News", url: "https://news.example/")
        #expect(safari.id == "7/3")
        #expect(safari.host == "news.example")
    }

    @Test func theListScriptsOutputDecodes() throws {
        let json = #"[{"window":"12","tabID":"40","index":0,"title":"Inbox","url":"https://mail.example/"}]"#
        let tabs = try JSONDecoder().decode([BrowserTab].self, from: Data(json.utf8))
        #expect(tabs.first?.id == "12/40")
    }

    @Test func browsersGetTabsAndOtherAppsDoNot() {
        func usage(_ bundleID: String) -> AppUsage {
            AppUsage(app: ProcessSample(pid: 1, name: "x", executablePath: nil, bundleIdentifier: bundleID, isRegularApp: true,
                                        isOwnedByUser: true, isNotResponding: false, state: .running, cpuPercent: 0, memoryBytes: 0),
                     memory: 0, cpu: 0, processCount: 1)
        }
        #expect(usage("company.thebrowser.dia").browser == .chromium)
        #expect(usage("com.apple.Safari").browser == .safari)
        #expect(usage("com.tinyspeck.slackmacgap").browser == nil)
    }
}
