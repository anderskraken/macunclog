import Foundation

/// Deletes what the user (or the schedule) picked, after checking every item again.
/// Minutes can pass between a scan and a click, and a dev server may have started in
/// the meantime, so the executor rescans the categories without sizes and only runs
/// items that are still cleanable with the same id.
enum CleanupExecutor {
    struct Progress: Sendable {
        let done: Int
        let total: Int
        let current: String
    }

    static func run(
        _ selected: [CleanupItem],
        trigger: CleanupRun.Trigger,
        activityWindow: TimeInterval,
        projectRoots: [URL],
        references: ExternalReferences? = nil,
        progress: @Sendable (Progress) async -> Void = { _ in }
    ) async -> CleanupRun? {
        let started = Date.now
        let freeBefore = SystemProbe.disk().available
        // The app, its fallback timer and the launchd agent can all start a clean-up.
        // Nil means another one holds the lock and nothing was done.
        guard let lock = CleanupLock.acquire() else { return nil }
        defer { CleanupLock.release(lock) }
        await progress(Progress(done: 0, total: selected.count, current: String(localized: "Checking that nothing is in use…")))

        let context = await ScanContext.capture(activityWindow: activityWindow, projectRoots: projectRoots, measureSizes: false,
                                                references: references)
        var fresh: [String: CleanupItem] = [:]
        for category in Set(selected.map(\.category)) {
            for item in await CleanupScanner.discover(category, in: context) { fresh[item.id] = item }
        }

        // The rescan can take minutes; a dev server started meanwhile must still stop a
        // deletion, so open files are read again right before each one.
        var inUse = await InUseSnapshot.capture()
        var inUseTakenAt = ContinuousClock.now

        var outcomes: [CleanupOutcome] = []
        var done = Set<String>()
        for (index, item) in selected.enumerated() where done.insert(item.id).inserted {
            await progress(Progress(done: index, total: selected.count, current: item.title))
            let result: CleanupOutcome.Result
            if let current = fresh[item.id] {
                if ContinuousClock.now - inUseTakenAt > .seconds(15) {
                    inUse = await InUseSnapshot.capture()
                    inUseTakenAt = .now
                }
                if let reason = current.blocked ?? current.guardPath.flatMap(inUse.blockReason(under:)) {
                    result = .skipped(reason.description)
                } else {
                    result = await perform(current.operation)
                }
            } else {
                result = .skipped(String(localized: "No longer exists"))
            }
            outcomes.append(CleanupOutcome(id: item.id, category: item.category, title: item.title, bytes: item.bytes, result: result))
        }
        await progress(Progress(done: selected.count, total: selected.count, current: String(localized: "Done")))

        return CleanupRun(id: UUID(), startedAt: started, finishedAt: .now, trigger: trigger,
                          freeBefore: freeBefore, freeAfter: SystemProbe.disk().available, outcomes: outcomes)
    }

    static func perform(_ operation: CleanupOperation) async -> CleanupOutcome.Result {
        switch operation {
        case .removeItem(let url):
            return await offMain { try SafeDeleter.removeItem(at: url) }
        case .removeContents(let url):
            return await offMain { try SafeDeleter.removeContents(of: url) }
        case .run(let command):
            let output = await Shell.run(command, timeout: .seconds(900))
            if output.succeeded { return .removed }
            let message = (output.stderr.nonEmpty ?? output.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(output.timedOut ? String(localized: "Timed out: \(command.display)") : String(message.prefix(300)))
        }
    }

    private static func offMain(_ work: @escaping @Sendable () throws -> Void) async -> CleanupOutcome.Result {
        await Task.detached(priority: .utility) {
            do {
                try work()
                return .removed
            } catch let violation as PathGuard.Violation {
                return .skipped(violation.description)
            } catch {
                return .failed(error.localizedDescription)
            }
        }.value
    }
}

/// An exclusive lock file in Application Support. The kernel drops it when the process
/// exits, so a crash can't leave it stuck.
enum CleanupLock {
    /// Tests run inside the app, so they lock a folder of their own and never block or
    /// get blocked by a real clean-up.
    static var folder: URL {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MacUnclogTests")
        }
        return HistoryStore.folder.deletingLastPathComponent()
    }

    static var isFree: Bool {
        guard let fd = acquire() else { return false }
        release(fd)
        return true
    }

    static func acquire() -> Int32? {
        let folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(folder.appendingPathComponent("cleanup.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    static func release(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
