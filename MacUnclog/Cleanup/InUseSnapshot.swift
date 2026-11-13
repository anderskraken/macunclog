import Foundation

/// One `lsof` pass over every process the user can see: working directories and open
/// files. Scanners ask it whether anything lives under a folder before offering it.
struct InUseSnapshot: Sendable {
    struct Entry: Sendable {
        let path: String
        let process: ProcessRef
        let isWorkingDirectory: Bool
    }

    /// Sorted by path so a folder query is a binary search.
    private let entries: [Entry]
    /// False when lsof failed. Every folder then counts as possibly in use.
    let isComplete: Bool

    init(entries: [Entry], isComplete: Bool = true) {
        self.entries = entries.sorted { $0.path < $1.path }
        self.isComplete = isComplete
    }

    static let unknown = InUseSnapshot(entries: [], isComplete: false)

    static func capture() async -> InUseSnapshot {
        let output = await Shell.run("/usr/sbin/lsof", ["-n", "-P", "-w", "-F", "pcfnR"], timeout: .seconds(60))
        guard !output.timedOut, output.stdout.contains("\nfcwd") else { return .unknown }
        return parse(output.stdout, excluding: [getpid()])
    }

    static func parse(_ text: String, excluding excluded: Set<pid_t> = []) -> InUseSnapshot {
        var entries: [Entry] = []
        var pid: pid_t = 0
        var command = ""
        var fd = ""
        // MacUnclog's own find and du runs, which may hold files open in a project right now.
        var excludedChildren = Set<pid_t>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()
            switch tag {
            case "p": pid = pid_t(value) ?? 0
            case "R": if pid_t(value) == getpid() { excludedChildren.insert(pid) }
            case "c": command = String(value)
            case "f": fd = String(value)
            case "n":
                guard value.hasPrefix("/"), !excluded.contains(pid), !excludedChildren.contains(pid), command != "lsof" else { continue }
                entries.append(Entry(
                    path: PathGuard.normalized(decodeEscapes(String(value))),
                    process: ProcessRef(pid: pid, name: command),
                    isWorkingDirectory: fd == "cwd"
                ))
            default: continue
            }
        }
        return InUseSnapshot(entries: entries)
    }

    /// lsof writes bytes it can't print as `\\xNN`. Turning them back into bytes keeps a
    /// path with "ø" comparable even if the locale was not UTF-8 after all.
    static func decodeEscapes(_ text: String) -> String {
        guard text.contains("\\x") else { return text }
        var bytes: [UInt8] = []
        var index = text.utf8.startIndex
        let utf8 = text.utf8
        while index < utf8.endIndex {
            let byte = utf8[index]
            if byte == UInt8(ascii: "\\"),
               let x = utf8.index(index, offsetBy: 1, limitedBy: utf8.endIndex), x < utf8.endIndex, utf8[x] == UInt8(ascii: "x"),
               let end = utf8.index(x, offsetBy: 3, limitedBy: utf8.endIndex),
               let value = UInt8(String(decoding: utf8[utf8.index(after: x)..<end], as: UTF8.self), radix: 16) {
                bytes.append(value)
                index = end
            } else {
                bytes.append(byte)
                index = utf8.index(after: index)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The process using something at or below `folder`, preferring one whose working
    /// directory is there, since that is the stronger signal (a dev server, a shell).
    func user(under folder: String) -> Entry? {
        let root = PathGuard.normalized(folder)
        let prefix = root + "/"
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].path < root { low = mid + 1 } else { high = mid }
        }
        var found: Entry?
        var index = low
        while index < entries.count {
            let entry = entries[index]
            guard entry.path == root || entry.path.hasPrefix(prefix) else {
                if entry.path > prefix { break }
                index += 1
                continue
            }
            if entry.isWorkingDirectory { return entry }
            found = found ?? entry
            index += 1
        }
        return found
    }

    func blockReason(under folder: String) -> BlockReason? {
        guard isComplete else { return .inUseUnknown }
        guard let entry = user(under: folder) else { return nil }
        return entry.isWorkingDirectory ? .workingDirectory(entry.process) : .openFile(entry.process)
    }
}
