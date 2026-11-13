import AppKit
import Darwin
import IOKit.ps

/// Reads everything the verdict needs in one pass: two samples about a second apart,
/// so CPU percentages and swap rates are real rates and not lifetime averages.
enum SystemProbe {
    @MainActor
    static func capture(sampleInterval: Duration = .milliseconds(800)) async -> SystemSnapshot {
        let apps = RunningApps.current()
        let interval = sampleInterval
        return await Task.detached(priority: .userInitiated) {
            await sample(apps: apps, interval: interval)
        }.value
    }

    /// Free space the way Finder counts it (purgeable space included). That figure comes
    /// from a system daemon which can stall for a background launchd job, so after three
    /// seconds this falls back to statfs, which leaves purgeable space out.
    static func disk() -> DiskSnapshot {
        let result = DiskBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let home = URL(fileURLWithPath: NSHomeDirectory())
            if let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
               let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacityForImportantUsage {
                result.set(DiskSnapshot(total: Int64(total), available: available))
            }
            done.signal()
        }
        if done.wait(timeout: .now() + 3) == .success, let snapshot = result.get() { return snapshot }
        return statfsDisk()
    }

    private static func statfsDisk() -> DiskSnapshot {
        var stats = statfs()
        guard statfs(NSHomeDirectory(), &stats) == 0 else { return DiskSnapshot(total: 0, available: 0) }
        let block = Int64(stats.f_bsize)
        return DiskSnapshot(total: Int64(stats.f_blocks) * block, available: Int64(stats.f_bavail) * block)
    }

    private final class DiskBox: @unchecked Sendable {
        private var value: DiskSnapshot?
        private let lock = NSLock()
        func set(_ snapshot: DiskSnapshot) { lock.withLock { value = snapshot } }
        func get() -> DiskSnapshot? { lock.withLock { value } }
    }

    private static func sample(apps: [pid_t: RunningApps.Info], interval: Duration) async -> SystemSnapshot {
        let firstTicks = cpuTicks()
        let firstVM = vmStatistics()
        let firstTimes = await processTimes()
        let start = ContinuousClock.now

        try? await Task.sleep(for: interval)

        let secondTicks = cpuTicks()
        let secondVM = vmStatistics()
        let secondTimes = await processTimes()
        let elapsed = (ContinuousClock.now - start).seconds

        let memory = memorySnapshot(first: firstVM, second: secondVM, elapsed: elapsed)
        let cpu = cpuSnapshot(first: firstTicks, second: secondTicks)
        let processes = processSamples(first: firstTimes, second: secondTimes, elapsed: elapsed, apps: apps)
        let usage = Dictionary(processes.map { ($0.pid, (cpu: $0.cpuPercent, memory: $0.memoryBytes)) }, uniquingKeysWith: { first, _ in first })
        let agents = await AgentProbe.capture(usage: usage)

        return SystemSnapshot(
            takenAt: .now,
            memory: memory,
            cpu: cpu,
            disk: disk(),
            thermal: ThermalLevel(ProcessInfo.processInfo.thermalState),
            power: power(),
            processes: processes,
            uptime: ProcessInfo.processInfo.systemUptime,
            agents: agents
        )
    }

    // MARK: Memory

    private static func vmStatistics() -> vm_statistics64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        return stats
    }

    private static func memorySnapshot(first: vm_statistics64, second: vm_statistics64, elapsed: Double) -> MemorySnapshot {
        let page = UInt64(getpagesize())
        let swapDelta = Double((second.swapins &- first.swapins) &+ (second.swapouts &- first.swapouts))
        let swap = swapUsage()
        let anonymous = UInt64(second.internal_page_count)
        let purgeable = UInt64(second.purgeable_count)
        return MemorySnapshot(
            total: ProcessInfo.processInfo.physicalMemory,
            appMemory: (anonymous > purgeable ? anonymous - purgeable : 0) * page,
            wired: UInt64(second.wire_count) * page,
            compressed: UInt64(second.compressor_page_count) * page,
            cached: (UInt64(second.external_page_count) + purgeable) * page,
            free: UInt64(second.free_count) * page,
            swapUsed: swap.used,
            swapTotal: swap.total,
            pressure: pressureLevel(),
            swapPagesPerSecond: elapsed > 0 ? swapDelta / elapsed : 0
        )
    }

    private static func swapUsage() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    private static func pressureLevel() -> MemoryPressure {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return MemoryPressure(rawValue: Int(level)) ?? .normal
    }

    // MARK: CPU

    private struct Ticks { var busy: UInt64; var total: UInt64 }

    private static func cpuTicks() -> Ticks {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return Ticks(busy: user + system + nice, total: user + system + idle + nice)
    }

    private static func cpuSnapshot(first: Ticks, second: Ticks) -> CPUSnapshot {
        let total = second.total &- first.total
        let busy = second.busy &- first.busy
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return CPUSnapshot(
            usage: total == 0 ? 0 : min(1, Double(busy) / Double(total)),
            load1: loads[0],
            load5: loads[1],
            cores: ProcessInfo.processInfo.activeProcessorCount
        )
    }

    // MARK: Processes

    private struct ProcessTime {
        var cpuNanos: UInt64
        var memory: UInt64
        var uid: uid_t
        var status: UInt32
        var name: String
        var path: String?
        var fromPS = false
        var startSeconds: UInt64 = 0
    }

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    /// libproc for everything the user may read, then `ps` (setuid root) for the rest,
    /// so root daemons such as WindowServer and kernel_task are measured too.
    private static func processTimes() async -> [pid_t: ProcessTime] {
        var result = libprocTimes()
        for (pid, time) in await psTimes() where result[pid] == nil {
            result[pid] = time
        }
        return result
    }

    private static func psTimes() async -> [pid_t: ProcessTime] {
        let output = await Shell.run("/bin/ps", ["-A", "-o", "pid=,uid=,rss=,time=,state=,comm="], timeout: .seconds(10))
        var result: [pid_t: ProcessTime] = [:]
        for line in output.stdout.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6, let pid = pid_t(fields[0]), let uid = uid_t(fields[1]), let rss = UInt64(fields[2]) else { continue }
            let path = String(fields[5])
            result[pid] = ProcessTime(
                cpuNanos: parseCPUTime(String(fields[3])),
                memory: rss * 1024,
                uid: uid,
                status: fields[4].hasPrefix("T") ? UInt32(SSTOP) : fields[4].hasPrefix("Z") ? UInt32(SZOMB) : 0,
                name: URL(fileURLWithPath: path).lastPathComponent,
                path: path.hasPrefix("/") ? path : nil,
                fromPS: true
            )
        }
        return result
    }

    /// Parses `ps` CPU time: "[[dd-]hh:]mm:ss.cc".
    static func parseCPUTime(_ text: String) -> UInt64 {
        var days = 0.0
        var rest = Substring(text)
        if let dash = rest.firstIndex(of: "-") {
            days = Double(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        let seconds = rest.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) } + days * 86_400
        return UInt64(seconds * 1_000_000_000)
    }

    private static func libprocTimes() -> [pid_t: ProcessTime] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        var result: [pid_t: ProcessTime] = [:]
        result.reserveCapacity(count)
        for pid in pids.prefix(max(count, 0)) where pid > 0 {
            var task = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize else { continue }
            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            let hasBSD = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize

            var memory = task.pti_resident_size
            var usage = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            if ok == 0 { memory = usage.ri_phys_footprint }

            let ticks = task.pti_total_user + task.pti_total_system
            result[pid] = ProcessTime(
                cpuNanos: ticks * timebase.numer / timebase.denom,
                memory: memory,
                uid: hasBSD ? bsd.pbi_uid : 0,
                status: hasBSD ? bsd.pbi_status : 0,
                name: hasBSD ? processName(pid: pid, bsd: bsd) : "pid \(pid)",
                path: nil,
                startSeconds: hasBSD ? bsd.pbi_start_tvsec : 0
            )
        }
        return result
    }

    private static func processName(pid: pid_t, bsd: proc_bsdinfo) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        var comm = bsd.pbi_comm
        return withUnsafeBytes(of: &comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// proc_name stops at 32 characters ("Browser Helper (Aperitif Render").
    private static func fullName(_ name: String, path: String?) -> String {
        guard let path, name.count >= 15 else { return name }
        let last = URL(fileURLWithPath: path).lastPathComponent
        return last.hasPrefix(name) ? last : name
    }

    private static let interpreters: Set<String> = ["Python", "python", "python3", "node", "ruby", "java", "bun", "deno", "perl", "php"]

    /// "Python" says little; "Python (whisper)" says what is running.
    private static func interpreterAwareName(pid: pid_t, name: String) -> String {
        guard interpreters.contains(name),
              let script = arguments(pid: pid).dropFirst().first(where: { !$0.hasPrefix("-") })
        else { return name }
        let base = URL(fileURLWithPath: script).lastPathComponent
        return base.isEmpty ? name : "\(name) (\(base))"
    }

    private static func arguments(pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size && buffer[index] != 0 { index += 1 }
        while index < size && buffer[index] == 0 { index += 1 }
        var result: [String] = []
        while index < size && result.count < Int(argc) {
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            result.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }

    private static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func processSamples(
        first: [pid_t: ProcessTime],
        second: [pid_t: ProcessTime],
        elapsed: Double,
        apps: [pid_t: RunningApps.Info]
    ) -> [ProcessSample] {
        let me = getuid()
        return second.compactMap { pid, now in
            // libproc counts nanoseconds and ps centiseconds; only compare like with like.
            let previous = first[pid].flatMap { $0.fromPS == now.fromPS ? $0 : nil }
            let before = previous?.cpuNanos ?? now.cpuNanos
            let delta = now.cpuNanos > before ? now.cpuNanos - before : 0
            let cpu = elapsed > 0 && now.status != UInt32(SZOMB) ? Double(delta) / (elapsed * 1_000_000_000) * 100 : 0
            let app = apps[pid]
            let path = now.path ?? executablePath(pid: pid)
            let state: ProcessSample.RunState = switch now.status {
            case UInt32(SSTOP): .stopped
            case UInt32(SZOMB): .zombie
            default: .running
            }
            return ProcessSample(
                pid: pid,
                name: app?.name ?? interpreterAwareName(pid: pid, name: fullName(now.name, path: path)),
                executablePath: path,
                bundleIdentifier: app?.bundleIdentifier,
                isRegularApp: app?.isRegular ?? false,
                isOwnedByUser: now.uid == me,
                isNotResponding: app?.isNotResponding ?? false,
                state: state,
                cpuPercent: max(0, cpu),
                memoryBytes: now.memory,
                startSeconds: now.startSeconds
            )
        }
    }

    // MARK: Power

    private static func power() -> PowerSnapshot {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return PowerSnapshot(onBattery: false, batteryPercent: nil, lowPowerMode: lowPower) }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            return PowerSnapshot(onBattery: onBattery, batteryPercent: max > 0 ? current * 100 / max : nil, lowPowerMode: lowPower)
        }
        return PowerSnapshot(onBattery: false, batteryPercent: nil, lowPowerMode: lowPower)
    }
}

extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
