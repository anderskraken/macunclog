import Foundation

/// What `xcrun simctl` reports about simulators and runtimes, decoded once per scan.
struct SimulatorInventory: Sendable {
    struct Device: Sendable, Decodable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool
        let dataPath: String?
        let dataPathSize: Int64?
        let lastUsedAt: Date?
        var runtime: String = ""

        var isBooted: Bool { state != "Shutdown" }

        private enum CodingKeys: String, CodingKey {
            case udid, name, state, isAvailable, dataPath, dataPathSize, lastUsedAt
        }
    }

    struct Runtime: Sendable, Decodable {
        let identifier: String
        let runtimeIdentifier: String?
        let version: String?
        let build: String?
        let sizeBytes: Int64?
        let deletable: Bool?
        let lastUsedAt: Date?
        let platformIdentifier: String?

        var displayName: String {
            let platform = switch platformIdentifier ?? "" {
            case let p where p.contains("iphone"): "iOS"
            case let p where p.contains("watch"): "watchOS"
            case let p where p.contains("appletv"): "tvOS"
            case let p where p.contains("xr"): "visionOS"
            default: "Simulator"
            }
            let version = version ?? runtimeIdentifier?.split(separator: ".").last.map(String.init) ?? "?"
            return "\(platform) \(version)" + (build.map { " (\($0))" } ?? "")
        }
    }

    var devices: [Device]
    var runtimes: [Runtime]
    /// False when simctl's device list could not be read. Then nothing may be
    /// treated as unused, because every runtime would look unused.
    var devicesKnown: Bool
    /// Runtime identifier to device count in every other device set on the Mac: test
    /// clones, Xcode previews and project-local sets such as `.ios27/devices`.
    var otherSetUsers: [String: Int] = [:]

    var anyBooted: Bool { devices.contains(where: \.isBooted) }

    /// Devices in the default set plus devices in other sets that need this runtime.
    func usageCount(of runtime: Runtime) -> Int {
        guard let id = runtime.runtimeIdentifier else { return 0 }
        return devices.filter { $0.runtime == id }.count + (otherSetUsers[id] ?? 0)
    }

    static let empty = SimulatorInventory(devices: [], runtimes: [], devicesKnown: false)

    static func load(projectRoots: [URL] = []) async -> SimulatorInventory {
        guard Shell.developerToolsInstalled else { return .empty }
        async let others = otherDeviceSets(projectRoots: projectRoots)
        async let deviceOutput = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"], timeout: .seconds(60))
        async let runtimeOutput = Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"], timeout: .seconds(60))
        let devicesJSON = await deviceOutput
        let runtimesJSON = await runtimeOutput
        var inventory = parse(devicesJSON: Data(devicesJSON.stdout.utf8), runtimesJSON: Data(runtimesJSON.stdout.utf8))
        guard let otherSets = await others else { return .empty }
        inventory.otherSetUsers = runtimeUsers(inSets: otherSets)
        return inventory
    }

    /// Every device set outside the default one. Nil when the search failed, which makes
    /// the caller offer no runtimes at all.
    static func otherDeviceSets(projectRoots: [URL]) async -> [URL]? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var sets = [
            "Library/Developer/XCTestDevices",
            "Library/Developer/Xcode/UserData/Previews/Simulator Devices",
            "Library/Developer/XCPGDevices",
        ].map { home.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        for root in CleanupScanner.distinctRoots(projectRoots).map({ $0.resolvingSymlinksInPath() }) {
            // No protected-folder prunes here: this search only reads, and a device set inside a
            // protected folder still needs its runtime.
            let output = await Shell.run("/usr/bin/find", [
                root.path, "-xdev", "-maxdepth", "10",
                "(", "-name", "node_modules", "-o", "-name", ".git", ")", "-prune",
                "-o", "-name", "device_set.plist", "-print",
            ], timeout: .seconds(180))
            guard output.succeeded else { return nil }
            sets += output.stdout.split(separator: "\n").map { URL(fileURLWithPath: String($0)).deletingLastPathComponent() }
        }
        return sets
    }

    static func runtimeUsers(inSets sets: [URL]) -> [String: Int] {
        var users: [String: Int] = [:]
        for set in sets {
            for device in CleanupScanner.children(of: set) {
                let plist = NSDictionary(contentsOf: device.appendingPathComponent("device.plist"))
                if let runtime = plist?["runtime"] as? String { users[runtime, default: 0] += 1 }
            }
        }
        return users
    }

    static func parse(devicesJSON: Data, runtimesJSON: Data) -> SimulatorInventory {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        struct DeviceList: Decodable { let devices: [String: [Device]] }

        guard let list = try? decoder.decode(DeviceList.self, from: devicesJSON) else { return .empty }
        let devices = list.devices.flatMap { runtime, entries in
            entries.map { var device = $0; device.runtime = runtime; return device }
        }
        let runtimes = (try? decoder.decode([String: Runtime].self, from: runtimesJSON)).map { Array($0.values) } ?? []
        return SimulatorInventory(devices: devices, runtimes: runtimes, devicesKnown: true)
    }
}
