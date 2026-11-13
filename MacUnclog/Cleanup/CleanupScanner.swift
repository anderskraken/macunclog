import AppKit

struct ScanContext: Sendable {
    var inUse: InUseSnapshot
    var simulators: SimulatorInventory
    var activityWindow: TimeInterval
    var projectRoots: [URL]
    var external: ExternalReferences = .empty
    /// The shared walk of the project folders; computed on demand when nil.
    var index: ProjectIndex? = nil
    var now: Date = .now
    /// Off for the safety re-check right before deleting, where only the verdict matters.
    var measureSizes: Bool = true

    private static func loadReferences(override: ExternalReferences?, projectConfigs: [String]?) async -> ExternalReferences {
        if let override { return override }
        return ExternalReferences.capture(projectConfigs: projectConfigs)
    }

    /// `references` replaces the scan of agent configs and links, for tests.
    static func capture(activityWindow: TimeInterval, projectRoots: [URL], measureSizes: Bool = true,
                        references: ExternalReferences? = nil) async -> ScanContext {
        async let inUse = InUseSnapshot.capture()
        async let defaultSet = SimulatorInventory.loadDefaultSet()
        let index = await ProjectIndex.scan(roots: projectRoots)
        var simulators = await defaultSet
        simulators.attachOtherSets(index.complete && index.errorFree ? index.deviceSets : nil)
        let external = await loadReferences(override: references, projectConfigs: index.complete ? index.mcpConfigs : nil)
        return await ScanContext(inUse: inUse, simulators: simulators, activityWindow: activityWindow,
                                 projectRoots: projectRoots, external: external, index: index, measureSizes: measureSizes)
    }
}

/// Finds cleanup candidates per category and decides, item by item, whether it is safe.
enum CleanupScanner {
    static let home = URL(fileURLWithPath: NSHomeDirectory())

    static func discover(_ category: CleanupCategory, in context: ScanContext) async -> [CleanupItem] {
        let items: [CleanupItem] = switch category {
        case .projectBuilds: await projectBuilds(context)
        case .xcode: await xcode(context)
        case .simulatorRuntimes: simulatorRuntimes(context)
        case .simulatorLeftovers: await simulatorLeftovers(context)
        case .idleSimulators: idleSimulators(context)
        case .deviceSupport: await deviceSupport(context)
        case .packageCaches: await packageCaches(context)
        case .updaterLeftovers: await updaterLeftovers(context)
        case .docker: await docker(context)
        }
        return items
            .filter { !context.measureSizes || $0.bytes > 0 }
            .sorted { ($0.blocked == nil ? 1 : 0, $0.bytes) > ($1.blocked == nil ? 1 : 0, $1.bytes) }
    }

    // MARK: Project build folders

    struct BuildFolderRule: Sendable {
        let names: Set<String>
        let namePrefix: String?
        let manifests: [String]
        let markers: [String]

        func matches(_ folder: URL) -> Bool {
            let name = folder.lastPathComponent
            guard names.contains(name) || namePrefix.map(name.hasPrefix) == true else { return false }
            let fm = FileManager.default
            let parent = folder.deletingLastPathComponent()
            let hasManifest = manifests.isEmpty || manifests.contains { fm.fileExists(atPath: parent.appendingPathComponent($0).path) }
            let hasMarker = markers.isEmpty || markers.contains { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
            return hasManifest && hasMarker
        }
    }

    static let buildFolderRules: [BuildFolderRule] = [
        BuildFolderRule(names: ["node_modules", ".next", ".turbo", ".svelte-kit", ".nuxt", ".parcel-cache"],
                        namePrefix: nil, manifests: ["package.json"], markers: []),
        BuildFolderRule(names: ["target"], namePrefix: nil, manifests: ["Cargo.toml"], markers: []),
        BuildFolderRule(names: [".build"], namePrefix: nil, manifests: ["Package.swift"], markers: []),
        BuildFolderRule(names: ["build"], namePrefix: nil, manifests: ["build.gradle", "build.gradle.kts"], markers: []),
        BuildFolderRule(names: ["DerivedData"], namePrefix: "dd-", manifests: [],
                        markers: ["Build", "ModuleCache.noindex", "Index.noindex", "Logs"]),
    ]

    static var buildFolderNames: Set<String> {
        buildFolderRules.reduce(into: Set<String>()) { $0.formUnion($1.names) }
    }

    static func defaultProjectRoots() -> [URL] {
        ["dev", "Developer", "Projects", "code", "src", "repos", "Code"]
            .map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .reduce(into: [URL]()) { roots, url in
                let real = url.resolvingSymlinksInPath().path.lowercased()
                if !roots.contains(where: { $0.resolvingSymlinksInPath().path.lowercased() == real }) { roots.append(url) }
            }
    }



    /// `-o -path <folder>` for each protected folder, so find never even walks into them.
    static var protectedPrunes: [String] {
        PathGuard.userProtected.flatMap { ["-o", "-path", globEscaped($0)] }
    }

    /// Drops roots that sit inside another root, so nothing is found twice.
    static func distinctRoots(_ roots: [URL]) -> [URL] {
        let paths = roots.map { PathGuard.normalized($0.resolvingSymlinksInPath().path) }
        return zip(roots, paths).filter { _, path in
            !paths.contains { other in other != path && path.lowercased().hasPrefix(other.lowercased() + "/") }
        }.reduce(into: [URL]()) { result, pair in
            if !result.contains(where: { $0.path.lowercased() == pair.0.path.lowercased() }) { result.append(pair.0) }
        }
    }

    private static func projectBuilds(_ context: ScanContext) async -> [CleanupItem] {
        guard Shell.developerToolsInstalled else { return [] }
        var index = context.index
        if index == nil { index = await ProjectIndex.scan(roots: context.projectRoots) }
        guard let index, index.complete else { return [] }
        var candidates: [URL] = []
        var seen = Set<String>()
        for folder in index.buildFolders where !folder.path.contains("/node_modules/") && buildFolderRules.contains(where: { $0.matches(folder) }) {
            if seen.insert(folder.path).inserted { candidates.append(folder) }
        }
        let links = index.buildLinks

        // Every step below runs per project in parallel; ProcessGate keeps it to eight tools.
        let relevantLinks = links.filter { seen.contains(PathGuard.normalized($0.resolvingSymlinksInPath().path)) }
        let parents = Set(candidates.map { $0.deletingLastPathComponent().path } + relevantLinks.map { $0.deletingLastPathComponent().path })
        let rootsByParent = await concurrentMap(Array(parents)) { await gitRoot(of: URL(fileURLWithPath: $0)) }
        var projects: [String: String] = [:]
        for folder in candidates {
            if let project = rootsByParent[folder.deletingLastPathComponent().path] ?? nil { projects[folder.path] = project }
        }
        let buildFoldersByProject = Dictionary(grouping: projects, by: \.value).mapValues { $0.map(\.key) }

        var allProjects = Set(projects.values)
        for link in relevantLinks {
            if let project = rootsByParent[link.deletingLastPathComponent().path] ?? nil { allProjects.insert(project) }
        }
        let verdicts = await concurrentMap(Array(allProjects)) { project in
            await projectVerdict(project, buildFolders: buildFoldersByProject[project] ?? [], context: context)
        }
        let ignored = await concurrentMap(Array(buildFoldersByProject.keys)) { project in
            await gitIgnored(buildFoldersByProject[project] ?? [], in: project)
        }

        // A worktree's node_modules can be a symlink into the main checkout. The target is
        // then only as idle as every project that links to it.
        var linkedBlocks: [String: BlockReason] = [:]
        for link in relevantLinks {
            let target = PathGuard.normalized(link.resolvingSymlinksInPath().path)
            // A link from outside any git repository can't be judged, so it keeps the target.
            guard let project = rootsByParent[link.deletingLastPathComponent().path] ?? nil else {
                linkedBlocks[target] = .linkedFrom(link.deletingLastPathComponent().lastPathComponent)
                continue
            }
            if verdicts[project]?.blocked != nil {
                linkedBlocks[target] = .linkedFrom(ProjectPlace(path: project).title)
            }
        }

        var pending: [(URL, String, BlockReason?)] = []
        for folder in candidates {
            guard let project = projects[folder.path] else {
                pending.append((folder, folder.deletingLastPathComponent().path, .notInGitRepository))
                continue
            }
            var reason = verdicts[project]?.blocked ?? linkedBlocks[folder.path]
            if reason == nil, let recent = recentModification(of: folder, window: context.activityWindow, now: context.now) {
                reason = .recentlyModified(recent)
            }
            if reason == nil, !(ignored[project]?.contains(folder.path) ?? false) {
                reason = .notGitIgnored
            }
            pending.append((folder, project, reason))
        }

        return await measure(pending.map { folder, project, reason in
            Candidate(
                id: "build:\(folder.path)", category: .projectBuilds,
                title: "\(ProjectPlace(path: project).title) · \(relative(folder, to: project))",
                location: folder.path, operation: .removeItem(folder),
                blocked: PathGuard.isProtected(folder.path) ? .protectedPath : reason,
                lastUsed: verdicts[project]?.lastActivity, guardPath: project
            )
        }, context: context)
    }

    struct ProjectVerdict: Sendable {
        let blocked: BlockReason?
        let lastActivity: Date?
    }

    /// The rule learned the hard way: a project is only touched when nothing in it changed
    /// inside the activity window and no process works in it or holds a file open there.
    static func projectVerdict(_ project: String, buildFolders: [String], context: ScanContext) async -> ProjectVerdict {
        if PathGuard.isProtected(project) { return ProjectVerdict(blocked: .protectedPath, lastActivity: nil) }
        if let reason = context.inUse.blockReason(under: project) { return ProjectVerdict(blocked: reason, lastActivity: nil) }
        if let reason = context.external.blockReason(for: project) { return ProjectVerdict(blocked: reason, lastActivity: nil) }
        switch await newestSourceChange(in: project, skipping: buildFolders, window: context.activityWindow) {
        case .failed: return ProjectVerdict(blocked: .activityUnknown, lastActivity: nil)
        case .changed(let date): return ProjectVerdict(blocked: .recentlyModified(date), lastActivity: date)
        case .quiet: break
        }
        let commit = await lastCommitDate(project)
        if let commit, context.now.timeIntervalSince(commit) < context.activityWindow {
            return ProjectVerdict(blocked: .recentlyModified(commit), lastActivity: commit)
        }
        return ProjectVerdict(blocked: nil, lastActivity: commit)
    }

    enum Activity: Equatable { case quiet, changed(Date), failed }

    /// Looks for any file changed inside the window, skipping only the exact build folders
    /// that would be deleted, so a source folder that happens to be named `build` counts.
    private static func newestSourceChange(in project: String, skipping buildFolders: [String], window: TimeInterval) async -> Activity {
        var arguments = [project, "-xdev", "-mindepth", "1", "(", "-name", ".git"]
        for folder in buildFolders { arguments += ["-o", "-path", globEscaped(folder)] }
        arguments += [")", "-prune", "-o", "-type", "f", "-mmin", "-\(max(1, Int(window / 60)))", "-print", "-quit"]
        let output = await Shell.run("/usr/bin/find", arguments, timeout: .seconds(90))
        let path = output.stdout.split(separator: "\n").first.map(String.init) ?? ""
        if !path.isEmpty { return .changed(modificationDate(path) ?? .now) }
        return output.succeeded ? .quiet : .failed
    }

    static func globEscaped(_ path: String) -> String {
        var result = ""
        for character in path {
            if "*?[]\\".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    private static func recentModification(of folder: URL, window: TimeInterval, now: Date) -> Date? {
        guard let date = modificationDate(folder.path), now.timeIntervalSince(date) < window else { return nil }
        return date
    }

    private static func gitRoot(of folder: URL) async -> String? {
        let output = await Shell.run("/usr/bin/git", ["-C", folder.path, "rev-parse", "--show-toplevel"], timeout: .seconds(20))
        let root = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.succeeded && !root.isEmpty ? root : nil
    }

    /// Runs `transform` for every key at once and collects the results by key.
    static func concurrentMap<Value: Sendable>(_ keys: [String], _ transform: @escaping @Sendable (String) async -> Value) async -> [String: Value] {
        await withTaskGroup(of: (String, Value).self) { group in
            for key in keys { group.addTask { (key, await transform(key)) } }
            var result: [String: Value] = [:]
            for await (key, value) in group { result[key] = value }
            return result
        }
    }

    /// The build folders git ignores in one project, asked in a single call.
    private static func gitIgnored(_ folders: [String], in project: String) async -> Set<String> {
        guard !folders.isEmpty else { return [] }
        let output = await Shell.run("/usr/bin/git", ["-C", project, "check-ignore", "--"] + folders, timeout: .seconds(30))
        // Exit 1 means none are ignored; anything above that is an error, and then none count.
        guard output.status == 0 || output.status == 1, !output.timedOut else { return [] }
        let listed = Set(output.stdout.split(separator: "\n").map { PathGuard.normalized(String($0)) })
        return Set(folders.filter { listed.contains(PathGuard.normalized($0)) })
    }



    private static func lastCommitDate(_ project: String) async -> Date? {
        let output = await Shell.run("/usr/bin/git", ["-C", project, "log", "-1", "--format=%ct"], timeout: .seconds(20))
        return TimeInterval(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).map(Date.init(timeIntervalSince1970:))
    }

    // MARK: Xcode

    private static func xcode(_ context: ScanContext) async -> [CleanupItem] {
        let derivedData = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        var candidates = children(of: derivedData).map { folder in
            let lastUsed = derivedDataLastUsed(folder)
            var reason = context.inUse.blockReason(under: folder.path)
            if reason == nil, let lastUsed, context.now.timeIntervalSince(lastUsed) < context.activityWindow {
                reason = .recentlyModified(lastUsed)
            }
            return Candidate(id: "xcode:\(folder.path)", category: .xcode,
                             title: derivedDataName(folder), location: folder.path,
                             operation: .removeItem(folder), blocked: reason, lastUsed: lastUsed)
        }
        for (title, path) in [
            (String(localized: "SwiftUI previews"), "Library/Developer/Xcode/UserData/Previews"),
            (String(localized: "Xcode cache"), "Library/Caches/com.apple.dt.Xcode"),
        ] {
            let folder = home.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            candidates.append(Candidate(id: "xcode:\(folder.path)", category: .xcode, title: title, location: folder.path,
                                        operation: .removeContents(folder),
                                        blocked: context.inUse.blockReason(under: folder.path),
                                        lastUsed: modificationDate(folder.path)))
        }
        return await measure(candidates, context: context)
    }

    private static func derivedDataName(_ folder: URL) -> String {
        let info = folder.appendingPathComponent("info.plist")
        if let plist = NSDictionary(contentsOf: info), let workspace = plist["WorkspacePath"] as? String {
            return URL(fileURLWithPath: workspace).deletingPathExtension().lastPathComponent
        }
        let name = folder.lastPathComponent
        return name.split(separator: "-").dropLast().joined(separator: "-").nonEmpty ?? name
    }

    private static func derivedDataLastUsed(_ folder: URL) -> Date? {
        let info = folder.appendingPathComponent("info.plist")
        let accessed = (NSDictionary(contentsOf: info)?["LastAccessedDate"] as? Date)
        let dates = [accessed, modificationDate(folder.path), modificationDate(folder.appendingPathComponent("Logs/Build").path)]
        return dates.compactMap { $0 }.max()
    }

    // MARK: Simulators

    private static func simulatorRuntimes(_ context: ScanContext) -> [CleanupItem] {
        let inventory = context.simulators
        guard inventory.devicesKnown else { return [] }
        return inventory.runtimes.compactMap { runtime in
            guard runtime.deletable != false, runtime.runtimeIdentifier != nil else { return nil }
            let users = inventory.usageCount(of: runtime)
            return CleanupItem(
                id: "runtime:\(runtime.identifier)", category: .simulatorRuntimes,
                title: runtime.displayName, location: runtime.runtimeIdentifier,
                bytes: runtime.sizeBytes ?? 0,
                operation: .run(Command(executable: "/usr/bin/xcrun", arguments: ["simctl", "runtime", "delete", runtime.identifier])),
                blocked: users == 0 ? nil : .runtimeInUse(devices: users),
                lastUsed: runtime.lastUsedAt
            )
        }
    }

    private static func simulatorLeftovers(_ context: ScanContext) async -> [CleanupItem] {
        let inventory = context.simulators
        var items: [CleanupItem] = []
        if inventory.devicesKnown {
            items += inventory.devices.filter { !$0.isAvailable }.map { device in
                CleanupItem(
                    id: "simdevice:\(device.udid)", category: .simulatorLeftovers,
                    title: String(localized: "\(device.name) (unavailable)"), location: device.dataPath,
                    bytes: device.dataPathSize ?? 0,
                    operation: .run(Command(executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", device.udid])),
                    blocked: device.isBooted ? .simulatorRunning : nil, lastUsed: device.lastUsedAt
                )
            }
        }
        var candidates: [Candidate] = []
        let testDevices = home.appendingPathComponent("Library/Developer/XCTestDevices")
        if !children(of: testDevices).isEmpty {
            candidates.append(Candidate(
                id: "simtesting", category: .simulatorLeftovers, title: String(localized: "Test clones (XCTestDevices)"),
                location: testDevices.path,
                operation: .run(Command(executable: "/usr/bin/xcrun", arguments: ["simctl", "--set", "testing", "delete", "all"])),
                blocked: context.inUse.blockReason(under: testDevices.path), lastUsed: modificationDate(testDevices.path)))
        }
        let caches = home.appendingPathComponent("Library/Developer/CoreSimulator/Caches")
        if !children(of: caches).isEmpty {
            let reason: BlockReason? = !inventory.devicesKnown || inventory.anyBooted
                ? .simulatorRunning : context.inUse.blockReason(under: caches.path)
            candidates.append(Candidate(
                id: "simcaches", category: .simulatorLeftovers, title: String(localized: "CoreSimulator cache"), location: caches.path,
                operation: .removeContents(caches), blocked: reason, lastUsed: modificationDate(caches.path)))
        }
        return items + (await measure(candidates, context: context))
    }

    static let idleSimulatorAge: TimeInterval = 30 * 86_400

    private static func idleSimulators(_ context: ScanContext) -> [CleanupItem] {
        guard context.simulators.devicesKnown else { return [] }
        return context.simulators.devices.compactMap { device in
            guard device.isAvailable else { return nil }
            let lastUsed = device.lastUsedAt ?? device.dataPath.flatMap(modificationDate)
            guard let lastUsed, context.now.timeIntervalSince(lastUsed) > idleSimulatorAge else { return nil }
            return CleanupItem(
                id: "simidle:\(device.udid)", category: .idleSimulators, title: device.name,
                location: device.dataPath, bytes: device.dataPathSize ?? 0,
                operation: .run(Command(executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", device.udid])),
                blocked: device.isBooted ? .simulatorRunning : nil, lastUsed: lastUsed
            )
        }
    }

    // MARK: Device support

    private static func deviceSupport(_ context: ScanContext) async -> [CleanupItem] {
        var candidates: [Candidate] = []
        for platform in ["iOS", "watchOS", "tvOS", "visionOS"] {
            let folder = home.appendingPathComponent("Library/Developer/Xcode/\(platform) DeviceSupport")
            let versions = children(of: folder)
                .map { ($0, modificationDate($0.path) ?? .distantPast) }
                .sorted { $0.1 > $1.1 }
            for (version, date) in versions.dropFirst() {
                var reason = context.inUse.blockReason(under: version.path)
                if reason == nil, context.now.timeIntervalSince(date) < context.activityWindow { reason = .recentlyModified(date) }
                candidates.append(Candidate(id: "devicesupport:\(version.path)", category: .deviceSupport,
                                            title: "\(platform) \(version.lastPathComponent)", location: version.path,
                                            operation: .removeItem(version), blocked: reason, lastUsed: date))
            }
        }
        return await measure(candidates, context: context)
    }

    // MARK: Caches

    static let packageCachePaths: [(title: String, path: String)] = [
        ("npm", ".npm/_cacache"),
        (String(localized: "pnpm store"), "Library/pnpm/store"),
        (String(localized: "pnpm metadata"), "Library/Caches/pnpm"),
        ("Yarn", "Library/Caches/Yarn"),
        ("Bun", ".bun/install/cache"),
        ("Gradle", ".gradle/caches"),
        ("CocoaPods", "Library/Caches/CocoaPods"),
        (String(localized: "Playwright browsers"), "Library/Caches/ms-playwright"),
        (String(localized: "Homebrew downloads"), "Library/Caches/Homebrew"),
        ("SwiftPM", "Library/Caches/org.swift.swiftpm"),
        (String(localized: "Go build cache"), "Library/Caches/go-build"),
        ("pip", "Library/Caches/pip"),
        ("uv", ".cache/uv"),
        (String(localized: "Cargo downloads"), ".cargo/registry/cache"),
        ("node-gyp", "Library/Caches/node-gyp"),
        (String(localized: "Electron downloads"), "Library/Caches/electron"),
    ]

    private static func packageCaches(_ context: ScanContext) async -> [CleanupItem] {
        let candidates = packageCachePaths.compactMap { entry -> Candidate? in
            let folder = home.appendingPathComponent(entry.path)
            guard !children(of: folder).isEmpty else { return nil }
            return Candidate(id: "cache:\(folder.path)", category: .packageCaches, title: entry.title,
                             location: folder.path, operation: .removeContents(folder),
                             blocked: context.inUse.blockReason(under: folder.path),
                             lastUsed: modificationDate(folder.path))
        }
        return await measure(candidates, context: context)
    }

    private static func updaterLeftovers(_ context: ScanContext) async -> [CleanupItem] {
        let caches = home.appendingPathComponent("Library/Caches")
        var folders: [URL] = []
        for child in children(of: caches) {
            if child.lastPathComponent.hasSuffix(".ShipIt") {
                folders.append(child)
                continue
            }
            for name in ["ShipIt", "org.sparkle-project.Sparkle"] {
                let nested = child.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: nested.path) { folders.append(nested) }
            }
        }
        let candidates = folders.map { folder in
            let bundleID = folder.lastPathComponent.hasSuffix(".ShipIt")
                ? String(folder.lastPathComponent.dropLast(".ShipIt".count))
                : folder.deletingLastPathComponent().lastPathComponent
            return Candidate(id: "updater:\(folder.path)", category: .updaterLeftovers, title: appName(bundleID),
                             location: folder.path, operation: .removeItem(folder),
                             blocked: context.inUse.blockReason(under: folder.path),
                             lastUsed: modificationDate(folder.path))
        }
        return await measure(candidates, context: context)
    }

    private static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    // MARK: Docker

    /// Only talks to a Docker that is already running. Starting Docker would also start
    /// every container with a restart policy, so a stopped Docker means no items.
    private static func docker(_ context: ScanContext) async -> [CleanupItem] {
        guard Shell.which("docker") != nil else { return [] }
        let info = await Shell.run("docker", ["info", "--format", "{{.ServerVersion}}"], timeout: .seconds(8))
        guard info.succeeded else { return [] }
        // Only a daemon on this Mac: a context or DOCKER_HOST pointing at a server is left alone.
        if let host = ProcessInfo.processInfo.environment["DOCKER_HOST"], !host.hasPrefix("unix://") { return [] }
        let endpoint = await Shell.run("docker", ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"], timeout: .seconds(8))
        guard endpoint.succeeded, endpoint.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("unix://") else { return [] }
        let df = await Shell.run("docker", ["system", "df", "--format", "{{.Type}}\t{{.Reclaimable}}"], timeout: .seconds(30))
        // `builder prune` acts on the current buildx builder, which can be a shared cloud or
        // Kubernetes cache. Only a builder on this Mac's own daemon may be pruned.
        let builder = await Shell.run("docker", ["buildx", "inspect"], timeout: .seconds(15))
        let driver = builder.stdout.split(separator: "\n")
            .first { $0.hasPrefix("Driver:") }?
            .dropFirst("Driver:".count).trimmingCharacters(in: .whitespaces)
        // A docker-container builder can still live on another machine; every node must point
        // at the current (local) context or a unix socket.
        let context = await Shell.run("docker", ["context", "show"], timeout: .seconds(8)).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoints = builder.stdout.split(separator: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Endpoint:") }
            .map { $0.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }
        let localEndpoints = !endpoints.isEmpty && endpoints.allSatisfy { $0 == context || $0.hasPrefix("unix://") }
        let localBuilder = builder.succeeded && (driver == "docker" || driver == "docker-container") && localEndpoints
        var buildCache: Int64 = 0
        for line in df.stdout.split(separator: "\n") where localBuilder {
            let parts = line.split(separator: "\t")
            if parts.count == 2, parts[0] == "Build Cache" { buildCache = DockerSize.parse(String(parts[1])) }
        }
        let dangling = await Shell.run("docker", ["images", "--filter", "dangling=true", "--format", "{{.Size}}"], timeout: .seconds(30))
        let danglingBytes = dangling.stdout.split(separator: "\n").reduce(Int64(0)) { $0 + DockerSize.parse(String($1)) }

        var items: [CleanupItem] = []
        if buildCache > 0 {
            items.append(CleanupItem(id: "docker:builder", category: .docker, title: String(localized: "Build cache"), location: "docker builder prune",
                                     bytes: buildCache,
                                     operation: .run(Command(executable: "docker", arguments: ["builder", "prune", "--force"])),
                                     blocked: nil, lastUsed: nil))
        }
        if danglingBytes > 0 {
            items.append(CleanupItem(id: "docker:dangling", category: .docker, title: String(localized: "Untagged images"), location: "docker image prune",
                                     bytes: danglingBytes,
                                     operation: .run(Command(executable: "docker", arguments: ["image", "prune", "--force"])),
                                     blocked: nil, lastUsed: nil))
        }
        return items
    }

    // MARK: Helpers

    struct Candidate: Sendable {
        let id: String
        let category: CleanupCategory
        let title: String
        let location: String
        let operation: CleanupOperation
        let blocked: BlockReason?
        let lastUsed: Date?
        var guardPath: String? = nil
    }

    private static func measure(_ candidates: [Candidate], context: ScanContext) async -> [CleanupItem] {
        await withTaskGroup(of: CleanupItem.self) { group in
            var iterator = candidates.makeIterator()
            func add(_ candidate: Candidate) {
                group.addTask {
                    let bytes = context.measureSizes ? await DiskUsage.size(of: candidate.location) : 1
                    return CleanupItem(id: candidate.id, category: candidate.category, title: candidate.title,
                                       location: candidate.location, bytes: bytes, operation: candidate.operation,
                                       blocked: candidate.blocked, lastUsed: candidate.lastUsed,
                                       guardPath: candidate.guardPath ?? (candidate.location.hasPrefix("/") ? candidate.location : nil))
                }
            }
            for _ in 0..<6 { if let next = iterator.next() { add(next) } }
            var results: [CleanupItem] = []
            for await item in group {
                results.append(item)
                if let next = iterator.next() { add(next) }
            }
            return results
        }
    }

    static func children(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private static func relative(_ folder: URL, to project: String) -> String {
        let path = folder.path
        return path.hasPrefix(project + "/") ? String(path.dropFirst(project.count + 1)) : folder.lastPathComponent
    }
}

/// `du` walks one directory at a time, which makes a 9 GB pnpm store take a minute and a
/// half. Below the first folder that fans out, the children are split into groups that
/// are measured in parallel.
enum DiskUsage {
    static func size(of path: String) async -> Int64 {
        var root = URL(fileURLWithPath: path)
        var children = CleanupScanner.children(of: root)
        while children.count == 1, (try? children[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              (try? children[0].resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true {
            root = children[0]
            children = CleanupScanner.children(of: root)
        }
        guard children.count >= 16 else { return await du([path]) }
        let groups = stride(from: 0, to: children.count, by: max(1, children.count / 8)).map {
            Array(children[$0..<min($0 + max(1, children.count / 8), children.count)]).map(\.path)
        }
        return await withTaskGroup(of: Int64.self) { group in
            for paths in groups { group.addTask { await du(paths) } }
            return await group.reduce(0, +)
        }
    }

    private static func du(_ paths: [String]) async -> Int64 {
        let output = await Shell.run("/usr/bin/du", ["-sk"] + paths, timeout: .seconds(300))
        return output.stdout.split(separator: "\n").reduce(Int64(0)) { total, line in
            total + (line.split(separator: "\t").first.flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } ?? 0) * 1024
        }
    }
}

enum DockerSize {
    /// Parses Docker's human sizes such as "1.2GB", "512.3MB (40%)" or "0B".
    static func parse(_ text: String) -> Int64 {
        let token = text.split(separator: " ").first.map(String.init) ?? ""
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (suffix, factor) in units where token.hasSuffix(suffix) {
            return Int64(((Double(token.dropLast(suffix.count)) ?? 0) * factor).rounded())
        }
        return 0
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
