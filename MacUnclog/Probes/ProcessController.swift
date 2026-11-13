import AppKit

/// Carries out quit, force quit, pause and resume, after asking ProcessPolicy again.
@MainActor
enum ProcessController {
    enum Failure: Error, CustomStringConvertible {
        case notAllowed(String)
        case signalFailed(String, Int32)
        case gone(String)

        var description: String {
            switch self {
            case .notAllowed(let name): String(localized: "MacUnclog isn’t allowed to touch \(name).")
            case .signalFailed(let name, let code):
                String(localized: "Couldn’t send a signal to \(name): \(String(cString: strerror(code)))")
            case .gone(let name): String(localized: "\(name) has already quit.")
            }
        }
    }

    static func perform(_ action: ProcessAction, on process: ProcessSample) throws(Failure) {
        guard ProcessPolicy.allowedActions(for: process).contains(action) else { throw .notAllowed(process.name) }
        guard isSameProcess(process) else { throw .gone(process.name) }
        let app = NSRunningApplication(processIdentifier: process.pid)
        switch action {
        case .quit:
            if let app, app.terminate() { return }
            try signal(SIGTERM, process)
        case .forceQuit:
            if let app, app.forceTerminate() { return }
            try signal(SIGKILL, process)
        case .pause:
            try signal(SIGSTOP, process)
        case .resume:
            try signal(SIGCONT, process)
        }
    }

    /// The pid still belongs to the process that was sampled (pids get reused).
    private static func isSameProcess(_ process: ProcessSample) -> Bool {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(process.pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return false }
        return process.startSeconds != 0 && bsd.pbi_start_tvsec == process.startSeconds
    }

    private static func signal(_ signal: Int32, _ process: ProcessSample) throws(Failure) {
        if kill(process.pid, signal) != 0 { throw .signalFailed(process.name, errno) }
    }
}
