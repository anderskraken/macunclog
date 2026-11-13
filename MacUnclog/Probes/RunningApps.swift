import AppKit

/// GUI apps by pid, with the "not responding" flag the Force Quit window uses.
@MainActor
enum RunningApps {
    struct Info: Sendable {
        let name: String
        let bundleIdentifier: String?
        let isRegular: Bool
        let isNotResponding: Bool
    }

    static func current() -> [pid_t: Info] {
        var result: [pid_t: Info] = [:]
        for app in NSWorkspace.shared.runningApplications {
            let regular = app.activationPolicy == .regular
            result[app.processIdentifier] = Info(
                name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
                bundleIdentifier: app.bundleIdentifier,
                isRegular: regular,
                isNotResponding: regular && HangDetector.isNotResponding(pid: app.processIdentifier)
            )
        }
        return result
    }
}

/// The window server tracks apps that stop answering events (the spinning beach ball).
/// There is no public API for it, so this resolves the SkyLight call at runtime and
/// answers "responding" whenever the symbols are missing.
enum HangDetector {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias UnresponsiveFn = @convention(c) (Int32, UnsafeRawPointer) -> Bool
    private typealias PSNForPIDFn = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32

    private struct Symbols: @unchecked Sendable {
        let connection: ConnectionFn
        let unresponsive: UnresponsiveFn
        let psnForPID: PSNForPIDFn
    }

    private static let symbols: Symbols? = {
        guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let connection = dlsym(skyLight, "SLSMainConnectionID") ?? dlsym(skyLight, "CGSMainConnectionID"),
              let unresponsive = dlsym(skyLight, "SLSEventIsAppUnresponsive") ?? dlsym(skyLight, "CGSEventIsAppUnresponsive"),
              let psn = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID")
        else { return nil }
        return Symbols(
            connection: unsafeBitCast(connection, to: ConnectionFn.self),
            unresponsive: unsafeBitCast(unresponsive, to: UnresponsiveFn.self),
            psnForPID: unsafeBitCast(psn, to: PSNForPIDFn.self)
        )
    }()

    static func isNotResponding(pid: pid_t) -> Bool {
        guard let symbols else { return false }
        var psn: (UInt32, UInt32) = (0, 0)
        let status = withUnsafeMutableBytes(of: &psn) { symbols.psnForPID(pid, $0.baseAddress!) }
        guard status == 0 else { return false }
        let connection = symbols.connection()
        return withUnsafeBytes(of: &psn) { symbols.unresponsive(connection, $0.baseAddress!) }
    }
}
