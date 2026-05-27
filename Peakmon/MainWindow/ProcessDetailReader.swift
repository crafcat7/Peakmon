//
//  ProcessDetailReader.swift
//  Peakmon
//
//  On-demand reader that builds a `ProcessDetail` for a single
//  PID using only public, entitlement-free Darwin APIs:
//
//    • `proc_pidpath`            — absolute executable path.
//    • `proc_pidinfo` /
//      `PROC_PIDTBSDINFO`        — ppid + start time + status.
//    • `proc_pidinfo` /
//      `PROC_PIDLISTTHREADS`     — thread IDs owned by the pid.
//    • `proc_pidinfo` /
//      `PROC_PIDTHREADINFO`      — per-thread cpu_user_time,
//                                  cpu_system_time, run_state,
//                                  thread name, priority.
//    • `KERN_PROCARGS2` sysctl   — argv[] / environment for
//                                  same-user processes.
//
//  None of these require `task_for_pid` (which needs the
//  `com.apple.security.cs.debugger` entitlement and typically
//  fails for ad-hoc-signed binaries against other processes),
//  and none trigger a TCC prompt. Cross-user processes (root
//  daemons) may return KERN_FAILURE on procargs / proc_pidpath
//  — in those cases the corresponding fields are left empty
//  rather than treated as an error, so the sheet still renders
//  with whatever subset of info we could collect.
//
//  Calling convention is one-shot, synchronous, off the main
//  thread is recommended for high-thread-count processes (a
//  WindowServer or a Chrome helper can have 60+ threads), but
//  in practice the whole call completes in <5ms so the sheet
//  body invokes it inline.
//

import Darwin
import Foundation

struct ThreadInfo: Identifiable, Hashable {
    let id: UInt64       // thread ID (`pth_threadid` is 64-bit)
    let name: String     // empty if unset (Apple never names most threads)
    let cpuUserMs: UInt64
    let cpuSystemMs: UInt64
    let runState: Int32  // TH_STATE_RUNNING / WAITING / STOPPED / HALTED / UNINTERRUPTIBLE
    let priority: Int32

    /// Total CPU time (user + system) in ms. Convenient for
    /// sorting threads by cost.
    var cpuTotalMs: UInt64 { cpuUserMs &+ cpuSystemMs }

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

struct ProcessDetail: Identifiable, Hashable {
    let id: Int32        // pid (matches `ProcessSnapshot.id` so we can drive `.sheet(item:)` interchangeably)
    let pid: Int32
    let ppid: Int32
    let path: String     // "" if cross-user or kernel task
    let args: [String]   // [argv[0], argv[1], …]; empty if procargs2 denied
    let startedAt: Date? // process start time, nil if unavailable
    let threads: [ThreadInfo]
}

enum ProcessDetailReader {
    /// Synchronously collect everything we can about `pid`.
    /// Always returns a value — missing fields stay empty —
    /// because the caller has nothing actionable to do with an
    /// error other than display "n/a", which is exactly what
    /// the empty fields render as in the sheet.
    ///
    /// Marked `nonisolated` so the sheet can call it from a
    /// detached background task without bouncing back to the
    /// main actor; nothing here touches shared mutable state.
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
    private static func readPath(pid: Int32) -> String {
        // `PROC_PIDPATHINFO_MAXSIZE` (= `MAXPATHLEN * 4`, 4096) is
        // not exposed to Swift through the libproc bridge, so we
        // hard-code the same value rather than reaching for the
        // C constant. Apple's headers have not changed this value
        // in over a decade.
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return "" }
        return String(cString: buf)
    }

    // MARK: - proc_pidinfo PROC_PIDTBSDINFO (ppid + start)

    /// Reads `proc_bsdinfo` for ppid + start time. `pbi_start_tvsec`
    /// is seconds since UNIX epoch; `pbi_start_tvusec` is the
    /// microsecond remainder. We surface the parent pid even
    /// when path/args are denied, so the sheet still shows
    /// useful lineage info for cross-user processes.
    private static func readPPID(pid: Int32) -> Int32 {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let got = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        guard got == Int32(size) else { return -1 }
        return Int32(bitPattern: info.pbi_ppid)
    }

    private static func readStartTime(pid: Int32) -> Date? {
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
    private static func readArgs(pid: Int32) -> [String] {
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

        // Skip past argc + exec_path (the exec path is a
        // null-terminated string immediately following argc;
        // some kernels pad it with additional NULs for
        // alignment, so we advance until we see a non-NUL byte
        // which marks the start of argv[0]).
        var cursor = MemoryLayout<Int32>.size
        // Walk past the exec_path string.
        while cursor < bufSize, buf[cursor] != 0 { cursor += 1 }
        // Walk past trailing NUL padding.
        while cursor < bufSize, buf[cursor] == 0 { cursor += 1 }

        var args: [String] = []
        args.reserveCapacity(Int(argc))

        for _ in 0..<argc {
            guard cursor < bufSize else { break }
            let start = cursor
            while cursor < bufSize, buf[cursor] != 0 { cursor += 1 }
            // `String(cString:)` requires a NUL terminator, which
            // we know exists at `cursor` because the loop above
            // either reached it or hit `bufSize` (in which case
            // we won't enter this branch on the next iteration).
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

    /// Returns up to ~512 threads' info. We allocate the list
    /// buffer twice the kernel's first reported size — that's
    /// the conventional pattern for `proc_pidinfo` list APIs,
    /// where the size returned by the first call can underestimate
    /// the upper bound if threads spawn between calls.
    ///
    /// CPU times come from `proc_threadinfo.pth_user_time` /
    /// `pth_system_time`, which are nanoseconds. We convert to
    /// milliseconds for display.
    private static func readThreads(pid: Int32) -> [ThreadInfo] {
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

            // `pth_name` is a fixed-size CChar tuple; bridging
            // through `withUnsafeBytes` lets us treat it as a
            // null-terminated C string without spelling out the
            // tuple shape (it's 64 bytes / `MAXTHREADNAMESIZE`).
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

        // Hottest threads first — same convention as the
        // process panel, gives the eye an immediate sense of
        // where the work is going inside the app.
        return out.sorted { $0.cpuTotalMs > $1.cpuTotalMs }
    }
}
