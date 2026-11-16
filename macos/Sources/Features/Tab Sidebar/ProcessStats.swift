import Darwin
import Foundation

/// The memory and CPU used by the processes running in a tab.
struct TabResourceUsage: Equatable {
    struct Process: Equatable {
        let name: String
        let memory: UInt64
        let cpu: Double
    }

    /// Physical memory footprint in bytes, as Activity Monitor's "Memory" column.
    var memory: UInt64

    /// CPU usage in percent of the whole machine (all cores), from 0 to 100.
    var cpu: Double

    /// The heaviest processes by memory.
    var top: [Process]

    /// Rounded to 10 MB and coarse percents so tiny fluctuations don't re-render the sidebar.
    func rounded() -> TabResourceUsage {
        let step: UInt64 = 10 * 1024 * 1024
        func roundMemory(_ value: UInt64) -> UInt64 { (value + step / 2) / step * step }

        // Usage relative to the whole machine is small, so keep a decimal below 10%.
        func roundCPU(_ value: Double) -> Double {
            value < 10 ? (value * 10).rounded() / 10 : value.rounded()
        }
        return TabResourceUsage(
            memory: roundMemory(memory),
            cpu: roundCPU(cpu),
            top: top.map { Process(name: $0.name, memory: roundMemory($0.memory), cpu: roundCPU($0.cpu)) })
    }
}

/// Samples process trees with libproc. CPU usage needs two samples, so this keeps the
/// previous CPU time of every process it has seen.
final class ProcessStats {
    private struct Sample {
        let cpuNanoseconds: UInt64
        let date: Date
    }

    private var previous: [pid_t: Sample] = [:]

    private static let coreCount = Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))
    private var sampledThisRound: Set<pid_t> = []

    /// `proc_pid_rusage` reports CPU time in Mach absolute time units, which are not
    /// nanoseconds on Apple silicon.
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    /// Sums usage over the given root processes and all of their descendants.
    func usage(roots: [pid_t], now: Date = Date()) -> TabResourceUsage {
        var processes: [TabResourceUsage.Process] = []
        for pid in Self.descendants(of: roots) {
            guard let rusage = Self.rusage(pid) else { continue }

            let cpuTime = (rusage.ri_user_time + rusage.ri_system_time) * Self.timebase.numer / Self.timebase.denom
            var cpu = 0.0
            if let last = previous[pid], cpuTime >= last.cpuNanoseconds {
                let wall = now.timeIntervalSince(last.date)
                if wall > 0 {
                    cpu = Double(cpuTime - last.cpuNanoseconds) / 1e9 / wall * 100 / Self.coreCount
                }
            }
            previous[pid] = Sample(cpuNanoseconds: cpuTime, date: now)
            sampledThisRound.insert(pid)

            processes.append(.init(name: Self.name(pid), memory: rusage.ri_phys_footprint, cpu: cpu))
        }

        return TabResourceUsage(
            memory: processes.reduce(0) { $0 + $1.memory },
            cpu: processes.reduce(0) { $0 + $1.cpu },
            top: Array(processes.sorted { $0.memory > $1.memory }.prefix(3)))
    }

    /// Call after sampling every tab to forget processes that have exited.
    func finishRound() {
        previous = previous.filter { sampledThisRound.contains($0.key) }
        sampledThisRound = []
    }

    // MARK: Process tree

    /// The process Ghostty started for a surface (usually `login` and the shell below it),
    /// found by walking up from the foreground process until the parent is Ghostty.
    static func rootPID(fromForeground pid: pid_t) -> pid_t? {
        let ghostty = getpid()
        var current = pid
        for _ in 0..<32 {
            guard let parent = parentPID(current) else { return nil }
            if parent == ghostty { return current }
            if parent <= 1 { return nil }
            current = parent
        }

        return nil
    }

    static func childPIDs(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let result = buffer.withUnsafeMutableBytes { bytes in
            proc_listchildpids(pid, bytes.baseAddress, Int32(bytes.count))
        }
        guard result > 0 else { return [] }

        // Depending on the macOS version the result is a count or a byte size, so read
        // at most the whole buffer and drop the unused zero entries.
        return buffer.prefix(min(Int(result), buffer.count)).filter { $0 > 0 }
    }

    static func descendants(of roots: [pid_t], limit: Int = 2000) -> [pid_t] {
        var seen: Set<pid_t> = []
        var queue = roots
        var result: [pid_t] = []
        while !queue.isEmpty && result.count < limit {
            let pid = queue.removeFirst()
            guard seen.insert(pid).inserted else { continue }
            result.append(pid)
            queue.append(contentsOf: childPIDs(of: pid))
        }

        return result
    }

    /// The current working directory of a process (only readable for our own processes).
    static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
            String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
        }
        guard let path, !path.isEmpty else { return nil }
        return path
    }

    static func path(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Uses sysctl rather than `proc_pidinfo` because the latter is denied for processes
    /// owned by another user, such as the setuid `login` that Ghostty starts shells with.
    private static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private static func rusage(_ pid: pid_t) -> rusage_info_v2? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }

        return result == 0 ? info : nil
    }

    /// A readable process name. Claude Code runs from a versioned binary, so name it.
    private static func name(_ pid: pid_t) -> String {
        guard let path = path(pid) else { return "pid \(pid)" }
        if path.contains("/claude/versions/") { return "claude" }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}
