import Foundation
import OSLog

/// Runs command-line tools with a timeout and a PATH that finds Homebrew and the
/// usual package managers, since a launchd agent starts with a bare environment.
enum Shell {
    private static let log = Logger(subsystem: "io.github.anderskraken.macunclog", category: "shell")

    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
        var timedOut = false
        var succeeded: Bool { status == 0 && !timedOut }
    }

    static let searchPath: [String] = {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "\(home)/Library/pnpm", "\(home)/.bun/bin", "\(home)/.cargo/bin", "\(home)/.local/bin",
            "/Applications/Docker.app/Contents/Resources/bin",
        ]
    }()

    /// git, xcrun and simctl are stubs that offer to install the Command Line Tools when
    /// they are missing, so check once whether a developer directory exists.
    static let developerToolsInstalled: Bool = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: path)
    }()

    static func which(_ tool: String) -> String? {
        if tool.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil }
        return searchPath.map { "\($0)/\(tool)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(_ command: Command, timeout: Duration = .seconds(600)) async -> Output {
        await run(command.executable, command.arguments, timeout: timeout)
    }

    static func run(_ tool: String, _ arguments: [String], timeout: Duration = .seconds(60)) async -> Output {
        guard let path = which(tool) else {
            return Output(status: 127, stdout: "", stderr: String(localized: "\(tool) not found"))
        }
        // Each run holds up to four threads (the waiter, two pipe readers, the termination
        // handler). A full scan would start dozens of du runs at once and starve the pool,
        // so at most eight tools run at a time.
        let queued = ContinuousClock.now
        await ProcessGate.shared.acquire()
        let started = ContinuousClock.now
        // Off Swift's cooperative pool: these calls block a thread for as long as the tool runs.
        let output = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(path: path, arguments: arguments, timeout: timeout))
            }
        }
        await ProcessGate.shared.release()
        log.debug("\(URL(fileURLWithPath: path).lastPathComponent, privacy: .public) \(arguments.prefix(16).joined(separator: " "), privacy: .private) waited \((started - queued).seconds, format: .fixed(precision: 2)) s, ran \((ContinuousClock.now - started).seconds, format: .fixed(precision: 2)) s")
        return output
    }

    private static func runBlocking(path: String, arguments: [String], timeout: Duration) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath.joined(separator: ":")
        environment["NO_COLOR"] = "1"
        // Without a UTF-8 locale lsof prints "ø" as "\\xc3\\xb8", and those paths would never match.
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment

        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let outData = LockedData(), errData = LockedData()
        let readers = DispatchGroup()
        for (pipe, sink) in [(stdout, outData), (stderr, errData)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                sink.append(pipe.fileHandleForReading.readDataToEndOfFile())
                readers.leave()
            }
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch {
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            return Output(status: 126, stdout: "", stderr: error.localizedDescription)
        }
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        let deadline = DispatchTime.now() + .milliseconds(Int(timeout.seconds * 1000))
        let timedOut = finished.wait(timeout: deadline) == .timedOut
        if timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 3)
            }
        }
        _ = readers.wait(timeout: .now() + 5)
        return Output(status: process.isRunning ? -1 : process.terminationStatus, stdout: outData.string, stderr: errData.string, timedOut: timedOut)
    }
}

private final class LockedData: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.withLock { data.append(chunk) }
    }

    var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

actor ProcessGate {
    static let shared = ProcessGate(limit: 8)

    private var available: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { available = limit }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty { available += 1 } else { waiting.removeFirst().resume() }
    }
}
