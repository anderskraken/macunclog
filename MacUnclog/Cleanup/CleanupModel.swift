import Foundation

/// The kinds of disk clutter MacUnclog knows how to remove. Every case says exactly
/// what it deletes; keep `whatIsDeleted` and the README table in step by hand.
enum CleanupCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case projectBuilds
    case xcode
    case simulatorRuntimes
    case simulatorLeftovers
    case idleSimulators
    case deviceSupport
    case packageCaches
    case updaterLeftovers
    case docker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .projectBuilds: String(localized: "Build files in inactive projects")
        case .xcode: String(localized: "Xcode build data")
        case .simulatorRuntimes: String(localized: "Unused simulator runtimes")
        case .simulatorLeftovers: String(localized: "Simulator leftovers")
        case .idleSimulators: String(localized: "Simulators unused for 30 days")
        case .deviceSupport: String(localized: "Old device support files")
        case .packageCaches: String(localized: "Package caches")
        case .updaterLeftovers: String(localized: "App update leftovers")
        case .docker: String(localized: "Docker cache")
        }
    }

    var symbol: String {
        switch self {
        case .projectBuilds: "shippingbox"
        case .xcode: "hammer"
        case .simulatorRuntimes: "iphone.gen3.badge.exclamationmark"
        case .simulatorLeftovers: "iphone.gen3.slash"
        case .idleSimulators: "iphone.gen3"
        case .deviceSupport: "cable.connector"
        case .packageCaches: "archivebox"
        case .updaterLeftovers: "arrow.down.app"
        case .docker: "cube.box"
        }
    }

    var whatIsDeleted: String {
        switch self {
        case .projectBuilds:
            String(localized: "node_modules, Rust target, .next, .turbo, .svelte-kit, .nuxt, .parcel-cache, .build, Gradle build and Xcode DerivedData (including .ios*/dd-*) inside project folders. Only when the folder is gitignored, nothing in the project changed recently, no process works in it or has a file open there, and nothing outside the project uses it. Not part of automatic clean-up unless you turn it on.")
        case .xcode:
            String(localized: "~/Library/Developer/Xcode/DerivedData, Xcode previews and Xcode’s own cache. Project folders that are in use or recently changed are skipped.")
        case .simulatorRuntimes:
            String(localized: "Simulator runtimes that no simulator uses, via xcrun simctl runtime delete. A runtime that a simulator needs is never deleted.")
        case .simulatorLeftovers:
            String(localized: "Simulators that macOS has marked as unavailable, test clones in XCTestDevices and the CoreSimulator cache. The cache is skipped while a simulator is running.")
        case .idleSimulators:
            String(localized: "Whole simulators (with their apps and data) that are shut down and haven’t been started in 30 days, via xcrun simctl delete.")
        case .deviceSupport:
            String(localized: "Symbol files in the iOS, watchOS, tvOS and visionOS DeviceSupport folders for older OS versions. The newest version for each platform is kept.")
        case .packageCaches:
            String(localized: "Download caches for npm, pnpm, Yarn, Bun, Gradle, CocoaPods, Playwright, Homebrew, SwiftPM, Go, pip, uv, Cargo, node-gyp and Electron. Everything is downloaded again when needed.")
        case .updaterLeftovers:
            String(localized: "Old update packages from ShipIt (Electron apps) and Sparkle in ~/Library/Caches.")
        case .docker:
            String(localized: "docker builder prune and docker image prune (untagged images only), on this Mac’s own Docker only. Stopped containers, volumes and tagged images are left alone, and MacUnclog never starts Docker.")
        }
    }

    /// Whether automatic cleanup includes the category unless the user turns it off.
    /// Automatic clean-up starts with the categories that can only cost a re-download.
    /// Build output, Docker and whole simulators are opt-in.
    var includedInAutomaticByDefault: Bool {
        ![.projectBuilds, .idleSimulators, .docker].contains(self)
    }
}

struct Command: Sendable, Hashable, Codable {
    let executable: String
    let arguments: [String]

    var display: String { ([URL(fileURLWithPath: executable).lastPathComponent] + arguments).joined(separator: " ") }
}

enum CleanupOperation: Sendable, Hashable {
    /// Delete the item itself.
    case removeItem(URL)
    /// Empty a cache folder but keep the folder.
    case removeContents(URL)
    case run(Command)
}

enum BlockReason: Sendable, Hashable {
    case recentlyModified(Date)
    case workingDirectory(ProcessRef)
    case openFile(ProcessRef)
    case notGitIgnored
    case notInGitRepository
    case runtimeInUse(devices: Int)
    case simulatorRunning
    case protectedPath
    case inUseUnknown
    case linkedFrom(String)
    case usedFromOutside(String)
    case configUnreadable(String)
    case activityUnknown

    var description: String {
        switch self {
        case .recentlyModified(let date): String(localized: "Changed \(Format.relative(date))")
        case .workingDirectory(let process): String(localized: "\(process.name) (pid \(process.pid)) is working in this folder")
        case .openFile(let process): String(localized: "\(process.name) (pid \(process.pid)) has a file open here")
        case .notGitIgnored: String(localized: "The folder isn’t gitignored")
        case .notInGitRepository: String(localized: "Not in a git repository, so MacUnclog can’t tell whether this is a build folder")
        case .runtimeInUse(let devices): devices == 1 ? String(localized: "One simulator uses this runtime") : String(localized: "\(devices) simulators use this runtime")
        case .simulatorRunning: String(localized: "A simulator is running")
        case .protectedPath: String(localized: "Protected folder")
        case .inUseUnknown: String(localized: "Couldn’t check which files are open")
        case .linkedFrom(let project): String(localized: "\(project) uses this folder through a symlink")
        case .usedFromOutside(let source): String(localized: "Used by something in \(source)")
        case .configUnreadable(let source): String(localized: "Couldn’t read \(source), so MacUnclog can’t tell what uses this")
        case .activityUnknown: String(localized: "Couldn’t read the whole project to see whether it’s in use")
        }
    }
}

struct CleanupItem: Identifiable, Sendable, Hashable {
    let id: String
    let category: CleanupCategory
    let title: String
    let location: String?
    let bytes: Int64
    let operation: CleanupOperation
    let blocked: BlockReason?
    let lastUsed: Date?
    /// The folder that must be free of running processes right before deletion: the
    /// project root for build folders, the item itself otherwise.
    var guardPath: String? = nil

    var isCleanable: Bool { blocked == nil && bytes > 0 }
}

struct CleanupOutcome: Identifiable, Sendable, Codable, Hashable {
    enum Result: Sendable, Codable, Hashable {
        case removed
        case skipped(String)
        case failed(String)
    }

    let id: String
    let category: CleanupCategory
    let title: String
    let bytes: Int64
    let result: Result
}

struct CleanupRun: Identifiable, Sendable, Codable, Hashable {
    enum Trigger: String, Sendable, Codable {
        case manual, schedule, lowDisk
    }

    let id: UUID
    let startedAt: Date
    let finishedAt: Date
    let trigger: Trigger
    let freeBefore: Int64
    let freeAfter: Int64
    let outcomes: [CleanupOutcome]

    var reclaimed: Int64 { outcomes.filter { $0.result == .removed }.reduce(0) { $0 + $1.bytes } }
    var removedCount: Int { outcomes.filter { $0.result == .removed }.count }
}
