//
//  LoadAverageReader.swift
//  Peakmon
//
//  Thin wrapper around the BSD `getloadavg(3)` system call. Returns
//  the standard 1-minute, 5-minute, and 15-minute load averages
//  the kernel maintains for the host.
//
//  Not added to `MetricsStore` because:
//    • Load averages are O(1) reads and don't need history,
//      sparklines, or the scheduler. Keeping them out of the store
//      avoids polluting `MetricKind` and the per-tick history
//      append path.
//    • Only the DashboardCPUCard reads them so far. If a future
//      v1.4 collector needs to graph load over time, that's the
//      time to promote it into the core.
//
//  Safe to call from `View.task` on the main actor; the underlying
//  syscall is non-blocking and synchronous. Reads cost roughly the
//  same as `host_statistics64` — well under a microsecond.
//
//  Caveat: load averages are *not* CPU percentage. They count
//  runnable threads, including ones blocked on I/O on BSD. A
//  load average of 4 on an 8-core box means "system is moderately
//  busy"; the dashboard card shows the raw numbers without trying
//  to normalise against core count, matching what `uptime` and
//  Activity Monitor show.
//

import Darwin

struct LoadAverageReader {
    /// One-, five-, and fifteen-minute load averages as reported
    /// by the kernel.
    struct Triplet: Equatable {
        var oneMinute: Double
        var fiveMinute: Double
        var fifteenMinute: Double

        static let zero = Triplet(oneMinute: 0, fiveMinute: 0, fifteenMinute: 0)
    }

    /// Reads the current load averages. Returns `Triplet.zero` if
    /// the syscall fails (it almost never does on macOS — listed
    /// failure modes in `man 3 getloadavg` only cover unusual
    /// kernel states).
    static func current() -> Triplet {
        var values = [Double](repeating: 0, count: 3)
        // `getloadavg` takes a raw C array. Use
        // `withUnsafeMutableBufferPointer` so Swift can hand the
        // base address over without forcing the array onto the
        // heap or risking lifetime issues across the call.
        let count = values.withUnsafeMutableBufferPointer { ptr in
            getloadavg(ptr.baseAddress, Int32(ptr.count))
        }
        guard count == 3 else { return .zero }
        return Triplet(
            oneMinute: values[0],
            fiveMinute: values[1],
            fifteenMinute: values[2],
        )
    }
}
