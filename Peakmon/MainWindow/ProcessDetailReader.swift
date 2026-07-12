//
//  ProcessDetailReader.swift
//  Peakmon
//
//  On-demand reader that builds a `ProcessDetail` for one PID using
//  only public, entitlement-free Darwin APIs:
//
//    • `proc_pidpath`                       — executable path.
//    • `proc_pidinfo` / `PROC_PIDTBSDINFO`  — ppid + start time.
//    • `proc_pidinfo` / `PROC_PIDLISTTHREADS`
//      + `PROC_PIDTHREADINFO`               — per-thread cpu time,
//                                             run state, name, prio.
//    • `KERN_PROCARGS2` sysctl              — argv for same-user pids.
//
//  None need `task_for_pid` (which requires a privileged entitlement
//  and usually fails for ad-hoc binaries against other processes)
//  and none trigger TCC. Cross-user processes may deny procargs /
//  proc_pidpath; those fields are left empty rather than treated as
//  errors, so the sheet renders with whatever subset we collected.
//
//  One-shot and synchronous; the sheet calls it off the main thread
//  (high-thread-count procs like WindowServer / Chrome helpers),
//  though it completes in <5 ms in practice.
//

import Darwin
import Foundation

struct ThreadInfo: Identifiable, Hashable, Sendable {
    let id: UInt64       // thread ID (`pth_threadid` is 64-bit)
    let name: String     // empty if unset (Apple never names most threads)
    let cpuUserMs: UInt64
    let cpuSystemMs: UInt64
    let runState: Int32  // TH_STATE_RUNNING / WAITING / STOPPED / HALTED / UNINTERRUPTIBLE
    let priority: Int32

    /// Total CPU time (user + system) in ms. Convenient for
    /// sorting threads by cost.
    nonisolated var cpuTotalMs: UInt64 { cpuUserMs &+ cpuSystemMs }

    /// Human-readable run state, mapped from the `TH_STATE_*`
    /// constants in `<mach/thread_info.h>`. Unknown values are
    /// returned numerically so we still display *something*.
    var runStateLabel: String {
        switch runState {
        case 1: return "running"
        case 2: return "stopped"
        case 3: return "waiting"
        case 4: return "uninterruptible"
        case 5: return "halted"
        default: return "state \(runState)"
        }
    }
}

struct ProcessDetail: Identifiable, Hashable, Sendable {
    let id: Int32        // pid (matches `ProcessSnapshot.id` so we can drive `.sheet(item:)` interchangeably)
    let pid: Int32
    let ppid: Int32
    let path: String     // "" if cross-user or kernel task
    let args: [String]   // [argv[0], argv[1], …]; empty if procargs2 denied
    let startedAt: Date? // process start time, nil if unavailable
    let threads: [ThreadInfo]
}

enum ProcessDetailReader {
    /// Synchronously collect everything readable about `pid`.
    /// Always returns a value (missing fields stay empty) since the
    /// caller only renders "n/a" on failure anyway.
    ///
    /// `nonisolated` so the sheet can call it from a detached task;
    /// nothing here touches shared mutable state.
    nonisolated static func read(pid: Int32) -> ProcessDetail {
        ProcessDetail(
            id: pid,
            pid: pid,
            ppid: readPPID(pid: pid),
            path: readPath(pid: pid),
            args: readArgs(pid: pid),
            startedAt: readStartTime(pid: pid),
            threads: readThreads(pid: pid),
        )
    }

    // MARK: - proc_pidpath

    /// Absolute executable path. Returns "" if the process is
    /// owned by another user or has exited between snapshot and
    /// sheet open.
    nonisolated private static func readPath(pid: Int32) -> String {
        // `PROC_PIDPATHINFO_MAXSIZE` (MAXPATHLEN * 4 = 4096) isn't
        // bridged to Swift, so hard-code it — Apple hasn't changed
        // the value in over a decade.
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return "" }
        let end = buf.firstIndex(of: 0) ?? buf.endIndex
        return String(decoding: buf[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - proc_pidinfo PROC_PIDTBSDINFO (ppid + start)

    /// Reads `proc_bsdinfo` for ppid. Surfaced even when path/args
    /// are denied so the sheet shows lineage for cross-user procs.
    nonisolated private static func readPPID(pid: Int32) -> Int32 {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let got = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        guard got == Int32(size) else { return -1 }
        return Int32(bitPattern: info.pbi_ppid)
    }

    nonisolated private static func readStartTime(pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let got = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        guard got == Int32(size) else { return nil }
        let secs = TimeInterval(info.pbi_start_tvsec)
        let usecs = TimeInterval(info.pbi_start_tvusec) / 1_000_000
        return Date(timeIntervalSince1970: secs + usecs)
    }

    // MARK: - KERN_PROCARGS2

    /// Reads argv[] for `pid` via the `KERN_PROCARGS2` sysctl.
    /// Layout (from `Libc/gen/FreeBSD/ps.c`):
    ///
    ///   int32 argc
    ///   char  exec_path[]  (null-padded to align)
    ///   char  argv[0][]    (null-terminated)
    ///   char  argv[1][]
    ///   ...
    ///   char  envp[0][]    (we stop reading at argc strings)
    ///
    /// Cross-user processes return EINVAL; kernel_task returns
    /// nothing useful. In both cases we return an empty array
    /// and let the sheet render "(arguments unavailable)".
    nonisolated private static func readArgs(pid: Int32) -> [String] {
        // First call: query the maximum argument size.
        var maxArgs: Int32 = 0
        var maxArgsSize = MemoryLayout<Int32>.size
        var mibMax: [Int32] = [CTL_KERN, KERN_ARGMAX]
        if sysctl(&mibMax, 2, &maxArgs, &maxArgsSize, nil, 0) != 0 || maxArgs <= 0 {
            return []
        }

        // Second call: fetch the actual argv blob.
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var bufSize = Int(maxArgs)
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        if sysctl(&mib, 3, buf, &bufSize, nil, 0) != 0 || bufSize < MemoryLayout<Int32>.size {
            return []
        }

        // Read argc out of the first 4 bytes.
        let argc = buf.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        guard argc > 0 else { return [] }

        // Skip argc + exec_path: the exec path is a null-terminated
        // string after argc, sometimes followed by NUL alignment
        // padding, so advance past both to reach argv[0].
        var cursor = MemoryLayout<Int32>.size
        while cursor < bufSize, buf[cursor] != 0 { cursor += 1 }
        while cursor < bufSize, buf[cursor] == 0 { cursor += 1 }

        var args: [String] = []
        args.reserveCapacity(Int(argc))

        for _ in 0..<argc {
            guard cursor < bufSize else { break }
            let start = cursor
            while cursor < bufSize, buf[cursor] != 0 { cursor += 1 }
            // NUL terminator guaranteed at `cursor` (the loop hit it
            // or `bufSize`, and we skip the latter case).
            if cursor < bufSize {
                let s = String(cString: buf.advanced(by: start))
                args.append(s)
                cursor += 1 // step past the NUL
            } else {
                break
            }
        }

        return args
    }

    // MARK: - proc_pidinfo PROC_PIDLISTTHREADS + PROC_PIDTHREADINFO

    /// Returns the pid's threads. The ID-list buffer is allocated
    /// at twice the kernel's first reported size — the usual pattern
    /// for `proc_pidinfo` list APIs, where threads may spawn between
    /// calls. CPU times (`pth_user_time` / `pth_system_time`) are
    /// nanoseconds, converted to ms for display.
    nonisolated private static func readThreads(pid: Int32) -> [ThreadInfo] {
        // 1. Size the thread ID list.
        let firstSize = proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, nil, 0)
        guard firstSize > 0 else { return [] }

        // 2. Allocate generously (×2) so a slightly-stale size
        //    doesn't truncate. Each entry is uint64_t.
        let entrySize = MemoryLayout<UInt64>.size
        let bufSize = Int(firstSize) * 2
        var threadIDs = [UInt64](repeating: 0, count: bufSize / entrySize)
        let filled = threadIDs.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return 0 }
            return proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, base, Int32(raw.count))
        }
        guard filled > 0 else { return [] }
        let count = Int(filled) / entrySize

        var out: [ThreadInfo] = []
        out.reserveCapacity(count)

        for i in 0..<count {
            let tid = threadIDs[i]
            var ti = proc_threadinfo()
            let sz = MemoryLayout<proc_threadinfo>.size
            let got = proc_pidinfo(pid, PROC_PIDTHREADINFO, tid, &ti, Int32(sz))
            guard got == Int32(sz) else { continue }

            // `pth_name` is a fixed CChar tuple (64 bytes /
            // MAXTHREADNAMESIZE); rebind through a pointer to read
            // it as a C string without spelling out the tuple.
            let name: String = withUnsafePointer(to: ti.pth_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: ti.pth_name)) {
                    String(cString: $0)
                }
            }

            out.append(ThreadInfo(
                id: tid,
                name: name,
                cpuUserMs: ti.pth_user_time / 1_000_000,
                cpuSystemMs: ti.pth_system_time / 1_000_000,
                runState: ti.pth_run_state,
                priority: ti.pth_priority,
            ))
        }

        // Hottest threads first — same convention as the process
        // panel.
        return out.sorted { $0.cpuTotalMs > $1.cpuTotalMs }
    }
}
