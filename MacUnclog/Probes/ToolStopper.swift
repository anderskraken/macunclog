import Foundation

/// Ends a tool and the processes it started: SIGTERM to all, then SIGKILL to whatever is
/// still alive three seconds later. Only the user's own processes can be signalled.
enum ToolStopper {
    static func stop(_ pids: [pid_t]) async {
        let me = getuid()
        let owned = pids.filter { pid in
            var bsd = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size && bsd.pbi_uid == me && pid > 1 && pid != getpid()
        }
        for pid in owned { kill(pid, SIGTERM) }
        for _ in 0..<30 {
            if owned.allSatisfy({ kill($0, 0) != 0 }) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        for pid in owned where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
}
