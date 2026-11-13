#if DEBUG
import Foundation

/// Made-up but realistic data for screenshots (`-MUDemo YES`), so they show no real
/// project names. The verdict and findings still come from the real rules.
enum DemoData {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "MUDemo") }

    private static let now = Date.now
    private static let gb: UInt64 = 1 << 30

    private static func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    private static func app(_ pid: pid_t, _ name: String, _ bundle: String, cpu: Double, memory: Double, path: String? = nil) -> ProcessSample {
        ProcessSample(pid: pid, name: name, executablePath: path ?? "/Applications/\(name).app/Contents/MacOS/\(name)",
                      bundleIdentifier: bundle, isRegularApp: true, isOwnedByUser: true, isNotResponding: false,
                      state: .running, cpuPercent: cpu, memoryBytes: UInt64(memory * Double(gb)))
    }

    private static func tool(_ pid: pid_t, _ name: String, _ path: String, cpu: Double, memory: Double, owned: Bool = true) -> ProcessSample {
        ProcessSample(pid: pid, name: name, executablePath: path, bundleIdentifier: nil, isRegularApp: false,
                      isOwnedByUser: owned, isNotResponding: false, state: .running, cpuPercent: cpu,
                      memoryBytes: UInt64(memory * Double(gb)))
    }

    static func snapshot() -> SystemSnapshot {
        let processes = [
            app(501, "Safari", "com.apple.Safari", cpu: 6, memory: 1.9, path: "/Applications/Safari.app/Contents/MacOS/Safari"),
            app(502, "Slack", "com.tinyspeck.slackmacgap", cpu: 3, memory: 2.4),
            app(503, "Xcode", "com.apple.dt.Xcode", cpu: 12, memory: 3.1),
            app(504, "Simulator", "com.apple.iphonesimulator", cpu: 9, memory: 0.6,
                path: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator"),
            app(505, "Figma", "com.figma.Desktop", cpu: 2, memory: 1.2),
            app(506, "Music", "com.apple.Music", cpu: 1, memory: 0.4, path: "/System/Applications/Music.app/Contents/MacOS/Music"),
            tool(610, "node", "/opt/homebrew/bin/node", cpu: 34, memory: 1.1),
            tool(611, "node", "/opt/homebrew/bin/node", cpu: 2, memory: 0.9),
            tool(612, "java", "/usr/bin/java", cpu: 1, memory: 1.3),
            tool(613, "swift-frontend", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend",
                 cpu: 186, memory: 0.8),
            tool(614, "cargo", "/Users/demo/.cargo/bin/cargo", cpu: 4, memory: 0.2),
            tool(615, "esbuild", "/Users/demo/dev/recipes-web/node_modules/@esbuild/darwin-arm64/bin/esbuild", cpu: 1, memory: 0.1),
            tool(620, "xcodebuild", "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild", cpu: 6, memory: 0.3),
            tool(621, "watchman", "/opt/homebrew/bin/watchman", cpu: 1, memory: 0.2),
            app(507, "Mail", "com.apple.mail", cpu: 1, memory: 0.5, path: "/System/Applications/Mail.app/Contents/MacOS/Mail"),
            app(508, "Notes", "com.apple.Notes", cpu: 0, memory: 0.3, path: "/System/Applications/Notes.app/Contents/MacOS/Notes"),
            app(509, "Calendar", "com.apple.iCal", cpu: 0, memory: 0.2, path: "/System/Applications/Calendar.app/Contents/MacOS/Calendar"),
            app(510, "Preview", "com.apple.Preview", cpu: 0, memory: 0.2, path: "/System/Applications/Preview.app/Contents/MacOS/Preview"),
            app(511, "Terminal", "com.apple.Terminal", cpu: 1, memory: 0.2, path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
            app(512, "Finder", "com.apple.finder", cpu: 1, memory: 0.3, path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"),
            tool(703, "photoanalysisd", "/System/Library/PrivateFrameworks/PhotoAnalysis.framework/Versions/A/Support/photoanalysisd",
                 cpu: 9, memory: 0.4, owned: true),
            tool(704, "Dock", "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock", cpu: 1, memory: 0.1),
            tool(705, "coreaudiod", "/usr/sbin/coreaudiod", cpu: 2, memory: 0.05, owned: false),
            tool(700, "WindowServer", "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
                 cpu: 18, memory: 0.3, owned: false),
            tool(701, "mds_stores", "/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Support/mds_stores",
                 cpu: 11, memory: 0.2, owned: false),
            tool(702, "kernel_task", "kernel_task", cpu: 7, memory: 0.1, owned: false),
        ]
        return SystemSnapshot(
            takenAt: now,
            memory: MemorySnapshot(total: 32 * gb, appMemory: 19 * gb, wired: 4 * gb, compressed: 6 * gb, cached: 2 * gb,
                                   free: gb / 2, swapUsed: 9 * gb, swapTotal: 10 * gb, pressure: .warning, swapPagesPerSecond: 240),
            cpu: CPUSnapshot(usage: 0.68, load1: 9.4, load5: 8.1, cores: 12),
            disk: DiskSnapshot(total: 994_662_584_320, available: 17_400_000_000),
            thermal: .fair,
            power: PowerSnapshot(onBattery: false, batteryPercent: 86, lowPowerMode: false),
            processes: processes,
            uptime: 3 * 86_400,
            agents: agents()
        )
    }

    private static let home = "/Users/demo"

    private static func agents() -> AgentLoad {
        let sessions = [
            AgentSession(pid: 801, kind: .claude, folder: "\(home)/dev/weather-app/.claude/worktrees/radar-map",
                         startedAt: ago(95), processCount: 31, cpuPercent: 212, memoryBytes: 3 * gb),
            AgentSession(pid: 802, kind: .claude, folder: "\(home)/dev/weather-app/.claude/worktrees/widget-refresh",
                         startedAt: ago(40), processCount: 14, cpuPercent: 48, memoryBytes: gb + gb / 2),
            AgentSession(pid: 803, kind: .codex, folder: "\(home)/dev/recipes-web",
                         startedAt: ago(220), processCount: 9, cpuPercent: 11, memoryBytes: gb),
            AgentSession(pid: 804, kind: .claude, folder: "\(home)/dev/budget-cli",
                         startedAt: ago(15), processCount: 4, cpuPercent: 3, memoryBytes: gb / 3),
        ]
        let simulators = [
            BootedSimulator(udid: "5A1C0D2E-0000-4000-8000-000000000001", name: "iPhone 17 Pro", runtime: "iOS 26.2",
                            bootedAt: ago(90), cpuPercent: 38, memoryBytes: 5 * gb,
                            users: [ProcessRef(pid: 620, name: "xcodebuild")], idleReason: nil),
            BootedSimulator(udid: "5A1C0D2E-0000-4000-8000-000000000002", name: "iPad Air 11-inch (M3)", runtime: "iOS 26.2",
                            bootedAt: ago(42), cpuPercent: 21, memoryBytes: 4 * gb, users: [], idleReason: nil),
            BootedSimulator(udid: "5A1C0D2E-0000-4000-8000-000000000003", name: "iPhone 17", runtime: "iOS 26.2",
                            bootedAt: ago(26 * 60), cpuPercent: 2, memoryBytes: 4 * gb, users: [],
                            idleReason: String(localized: "Started \(Format.relative(ago(26 * 60))), with no users and no load")),
            BootedSimulator(udid: "5A1C0D2E-0000-4000-8000-000000000004", name: "iPhone 16e", runtime: "iOS 18.6",
                            bootedAt: ago(3 * 60), cpuPercent: 1, memoryBytes: 3 * gb, users: [],
                            idleReason: String(localized: "Started \(Format.relative(ago(3 * 60))), with no users and no load")),
        ]
        func bytes(_ gigabytes: Double) -> UInt64 { UInt64(gigabytes * Double(gb)) }
        let tools = [
            ToolProcess(pid: 610, kind: .devServer, label: "Metro (Expo)", folder: "\(home)/dev/weather-app/.claude/worktrees/radar-map",
                        ports: [8081], owner: .session(801, .claude), startedAt: ago(80), processIDs: [610], cpuPercent: 34, memoryBytes: bytes(1.1)),
            ToolProcess(pid: 620, kind: .build, label: "xcodebuild", folder: "\(home)/dev/weather-app/.claude/worktrees/widget-refresh",
                        ports: [], owner: .session(802, .claude), startedAt: ago(4), processIDs: [620, 613], cpuPercent: 192, memoryBytes: bytes(1.1)),
            ToolProcess(pid: 611, kind: .devServer, label: "Vite", folder: "\(home)/dev/recipes-web/.claude/worktrees/search",
                        ports: [5173], owner: .orphaned, startedAt: ago(19 * 60), processIDs: [611, 615], cpuPercent: 3, memoryBytes: bytes(1.0)),
            ToolProcess(pid: 612, kind: .emulator, label: String(localized: "Firebase emulator"), folder: "\(home)/dev/recipes-web",
                        ports: [8080, 9099], owner: .orphaned, startedAt: ago(30 * 60), processIDs: [612], cpuPercent: 1, memoryBytes: bytes(1.3)),
            ToolProcess(pid: 614, kind: .build, label: "Cargo", folder: "\(home)/dev/budget-cli",
                        ports: [], owner: .terminal, startedAt: ago(2), processIDs: [614], cpuPercent: 4, memoryBytes: bytes(0.2)),
        ]
        return AgentLoad(sessions: sessions, simulators: simulators, tools: tools)
    }

    static func cleanup() -> [CleanupCategory: CategoryState] {
        func item(_ category: CleanupCategory, _ title: String, _ path: String, _ gigabytes: Double,
                  blocked: BlockReason? = nil, days: Double = 12) -> CleanupItem {
            CleanupItem(id: "demo:\(path)", category: category, title: title, location: "\(home)/\(path)",
                        bytes: Int64(gigabytes * 1e9), operation: .removeItem(URL(fileURLWithPath: "\(home)/\(path)")),
                        blocked: blocked, lastUsed: now.addingTimeInterval(-days * 86_400))
        }
        let items: [CleanupCategory: [CleanupItem]] = [
            .projectBuilds: [
                item(.projectBuilds, "weather-app › old-onboarding · node_modules", "dev/weather-app/.claude/worktrees/old-onboarding/node_modules", 1.6),
                item(.projectBuilds, "budget-cli · target", "dev/budget-cli/target", 7.8, days: 21),
                item(.projectBuilds, "recipes-web › search · .next", "dev/recipes-web/.claude/worktrees/search/.next", 0.6, days: 9),
                item(.projectBuilds, "weather-app › radar-map · node_modules", "dev/weather-app/.claude/worktrees/radar-map/node_modules", 1.4,
                     blocked: .workingDirectory(ProcessRef(pid: 610, name: "node")), days: 0),
                item(.projectBuilds, "weather-app › widget-refresh · .ios26/dd-sim", "dev/weather-app/.claude/worktrees/widget-refresh/.ios26/dd-sim", 6.2,
                     blocked: .recentlyModified(now.addingTimeInterval(-3600)), days: 0),
            ],
            .xcode: [item(.xcode, "WeatherApp", "Library/Developer/Xcode/DerivedData/WeatherApp-abc", 4.3, days: 6)],
            .simulatorRuntimes: [
                item(.simulatorRuntimes, "iOS 17.5 (21F79)", "rt-175", 7.9, days: 140),
                item(.simulatorRuntimes, "iOS 26.2 (23C54)", "rt-262", 8.4, blocked: .runtimeInUse(devices: 6), days: 0),
            ],
            .simulatorLeftovers: [item(.simulatorLeftovers, "iPhone 15 (unavailable)", "Library/Developer/CoreSimulator/Devices/old", 2.1, days: 80)],
            .packageCaches: [
                item(.packageCaches, "pnpm store", "Library/pnpm/store", 6.4, days: 1),
                item(.packageCaches, "npm", ".npm/_cacache", 1.2, days: 1),
                item(.packageCaches, "Gradle", ".gradle/caches", 2.9, blocked: .openFile(ProcessRef(pid: 612, name: "java")), days: 0),
            ],
            .updaterLeftovers: [item(.updaterLeftovers, "Slack", "Library/Caches/com.tinyspeck.slackmacgap.ShipIt", 0.3, days: 30)],
        ]
        var result: [CleanupCategory: CategoryState] = [:]
        for category in CleanupCategory.allCases {
            result[category] = CategoryState(items: items[category] ?? [], isScanning: false, scanned: true)
        }
        return result
    }

    static func history() -> [CleanupRun] {
        func run(daysAgo: Double, hours: Double, _ trigger: CleanupRun.Trigger, before: Double, _ outcomes: [CleanupOutcome]) -> CleanupRun {
            let start = now.addingTimeInterval(-(daysAgo * 86_400 + hours * 3600))
            let freed = outcomes.filter { $0.result == .removed }.reduce(Int64(0)) { $0 + $1.bytes }
            return CleanupRun(id: UUID(), startedAt: start, finishedAt: start.addingTimeInterval(80), trigger: trigger,
                              freeBefore: Int64(before * 1e9), freeAfter: Int64(before * 1e9) + freed + 40_000_000, outcomes: outcomes)
        }
        func removed(_ category: CleanupCategory, _ title: String, _ gigabytes: Double) -> CleanupOutcome {
            CleanupOutcome(id: title, category: category, title: title, bytes: Int64(gigabytes * 1e9), result: .removed)
        }
        let busy = BlockReason.workingDirectory(ProcessRef(pid: 610, name: "node")).description
        return [
            run(daysAgo: 0, hours: 3.4, .manual, before: 24.6, [
                removed(.packageCaches, "npm", 0.9),
                removed(.xcode, "RecipesKit", 2.2),
            ]),
            run(daysAgo: 2, hours: 5.2, .lowDisk, before: 16.2, [
                removed(.projectBuilds, "weather-app › legacy · node_modules", 1.3),
                removed(.packageCaches, "pnpm store", 5.9),
                removed(.simulatorRuntimes, "iOS 17.2 (21C62)", 7.1),
                CleanupOutcome(id: "busy", category: .projectBuilds, title: "weather-app › radar-map · node_modules",
                               bytes: 1_400_000_000, result: .skipped(busy)),
            ]),
            run(daysAgo: 5, hours: 20.7, .schedule, before: 38.9, [
                removed(.projectBuilds, "budget-cli · target", 4.6),
                removed(.updaterLeftovers, "Slack", 0.3),
            ]),
            run(daysAgo: 12, hours: 21.1, .schedule, before: 44.0, [
                removed(.packageCaches, "Homebrew downloads", 0.8),
                removed(.simulatorLeftovers, "iPhone 15 (unavailable)", 2.0),
            ]),
        ]
    }
}
#endif
