//
//  LoadAverageReader.swift
//  Peakmon
//
//  Thin wrapper around BSD `getloadavg(3)` — the kernel's 1/5/15-
//  minute load averages.
//
//  Kept out of `MetricsStore`: these are O(1) reads needing no
//  history or sparkline, and only the CPU card uses them. Safe from
//  `View.task` on the main actor (non-blocking, sub-microsecond).
//
//  Caveat: load average is *not* CPU percentage — it counts runnable
//  threads (including I/O-blocked ones on BSD). The card shows the
//  raw numbers without normalising against core count, matching
//  `uptime` and Activity Monitor.
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

    /// Reads the current load averages, or `Triplet.zero` on the
    /// (near-impossible) syscall failure.
    static func current() -> Triplet {
        var values = [Double](repeating: 0, count: 3)
        // `getloadavg` writes into a raw C array; hand it the base
        // address via the buffer pointer.
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
