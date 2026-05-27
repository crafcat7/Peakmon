//
//  PerCoreCPUReader.swift
//  Peakmon
//
//  Mach-level per-core CPU usage helper. The MetricsStore tracks
//  aggregate CPU only (`.cpuTotal/.cpuUser/.cpuSystem`); this
//  helper fills in per-core utilisation for the DashboardCPUCard
//  drill-down without expanding the core MetricKind enum or the
//  1Hz scheduler payload.
//
//  How it works
//  ────────────
//  `host_processor_info(_, PROCESSOR_CPU_LOAD_INFO, …)` returns a
//  contiguous integer array — `[user, system, idle, nice]` per
//  logical CPU — counting *ticks* since boot. To turn ticks into
//  a percentage you sample twice, diff each core's user+system
//  vs total, and divide. That's the same algorithm Activity
//  Monitor and `top` use.
//
//  Lifetime / state
//  ────────────────
//  The reader keeps the previous tick snapshot inside the actor
//  so each subsequent `sample()` returns instantaneous deltas
//  rather than since-boot averages. First call returns an empty
//  array (no baseline yet) — the caller renders a faint
//  "warming up" placeholder bar.
//
//  Not in MetricsStore because
//    • The data is only consumed by the expanded CPU card
//      drill-down. Pushing 8/12/16 extra series through the
//      ring-buffer history machinery for a feature that lives
//      inside a collapsible panel would be wasteful.
//    • The reader runs at the drill-down's own cadence (1 Hz via
//      TimelineView) — when the panel is collapsed no work
//      happens at all.
//

import Darwin
import Foundation
import MachO
import Darwin.Mach

/// Per-core utilisation reader. Instances are `@MainActor` because
/// the only consumer (`DashboardCPUCard`) lives on the main actor
/// and the underlying mach calls are cheap; bouncing across
/// actors would buy nothing.
@MainActor
final class PerCoreCPUReader {
    /// Cached per-core tick counts from the previous `sample()`.
    /// `nil` until the first reading — that first call cannot
    /// produce deltas yet.
    private var previous: [CoreTicks]?

    /// Rolling window of the last `windowSize` instantaneous
    /// per-core utilisation arrays. `averagedSample()` collapses
    /// it into one mean array so the UI gets a smoothed value
    /// without binarising on a single burst-filled window.
    /// Capacity is bounded so the reader's footprint is N cores
    /// × `windowSize` doubles — trivial on any Mac.
    private var ringBuffer: [[Double]] = []

    /// Length of the rolling-average window. Four samples paired
    /// with the caller's 2 Hz internal cadence and 1 Hz UI cadence
    /// means the UI publishes the mean of the four most recent
    /// 500 ms utilisation snapshots once per second — a 2 s
    /// smoothing window in total.
    private let windowSize = 4

    /// Cached CPU topology — split point between E-cores (first
    /// run of logical CPUs) and P-cores (remainder). Read once
    /// from `sysctl` and reused for the lifetime of the reader.
    let topology: Topology = .detect()

    /// Apple silicon perf-level topology. `host_processor_info`
    /// hands cores back in `sysctl` order: efficiency cores first,
    /// then performance cores. `firstPCoreIndex` records where
    /// E-cores end and P-cores begin so the bar chart can group
    /// them visually.
    struct Topology {
        /// Number of efficiency cores. On Intel Macs and on M-series
        /// machines without a distinct E-cluster this is 0 and every
        /// core renders as a P-core.
        let efficiencyCores: Int
        /// Number of performance cores.
        let performanceCores: Int

        /// Index of the first P-core inside the per-core array.
        /// Equal to `efficiencyCores`.
        var firstPCoreIndex: Int { efficiencyCores }

        /// Total logical core count (E + P).
        var totalCores: Int { efficiencyCores + performanceCores }

        /// Reads the perf-level breakdown from sysctl. On Apple
        /// silicon `hw.perflevel0.logicalcpu` is the performance
        /// cluster (highest perf = level 0, counterintuitively)
        /// and `hw.perflevel1.logicalcpu` is the efficiency
        /// cluster. On Intel both keys are absent and we return
        /// 0 / `hw.logicalcpu`, which collapses the UI grouping
        /// to a single P-band.
        static func detect() -> Topology {
            let p = sysctlInt("hw.perflevel0.logicalcpu") ?? 0
            let e = sysctlInt("hw.perflevel1.logicalcpu") ?? 0
            if p == 0 && e == 0 {
                let total = sysctlInt("hw.logicalcpu") ?? 0
                return Topology(efficiencyCores: 0, performanceCores: total)
            }
            return Topology(efficiencyCores: e, performanceCores: p)
        }

        private static func sysctlInt(_ name: String) -> Int? {
            var value: Int = 0
            var size = MemoryLayout<Int>.size
            let kr = sysctlbyname(name, &value, &size, nil, 0)
            return kr == 0 ? value : nil
        }
    }

    /// One core's cumulative user/system/idle/nice tick counts.
    private struct CoreTicks {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32

        /// Sum of all four channels — denominator for the
        /// utilisation ratio. Promoted to Double so the
        /// subtraction in `delta(from:)` does not underflow when
        /// the kernel resets a counter (rare but possible after
        /// CPU hotplug events on Asahi-style kernels).
        var total: Double {
            Double(user) + Double(system) + Double(idle) + Double(nice)
        }
    }

    /// Computes per-core utilisation since the previous sample
    /// and feeds it into the rolling-average ring buffer.
    /// Returns the instantaneous (single-window) value. Most UI
    /// callers want `averagedSample()` instead.
    ///
    /// Algorithm
    ///   1. Ask the host for the current tick array.
    ///   2. For each core, subtract previous user+sys+idle+nice;
    ///      divide busy delta (user+sys) by total delta.
    ///   3. Push the resulting array onto `ringBuffer`, trimming
    ///      from the front so length never exceeds `windowSize`.
    ///   4. Stash the new tick snapshot for next time.
    @discardableResult
    func sample() -> [Double] {
        guard let current = readHostProcessorInfo() else {
            return previous == nil ? [] : Array(repeating: 0, count: previous?.count ?? 0)
        }
        defer { previous = current }

        guard let previous, previous.count == current.count else {
            return [] // first call, or core count changed (hotplug)
        }

        let instant = zip(previous, current).map { prev, now -> Double in
            let totalDelta = now.total - prev.total
            guard totalDelta > 0 else { return 0 }
            let busyDelta = Double(now.user &- prev.user)
                + Double(now.system &- prev.system)
                + Double(now.nice &- prev.nice)
            return max(0, min(1, busyDelta / totalDelta))
        }

        ringBuffer.append(instant)
        if ringBuffer.count > windowSize {
            ringBuffer.removeFirst(ringBuffer.count - windowSize)
        }
        return instant
    }

    /// Per-core mean of the rolling window. Drives the UI; the
    /// window smooths over the binary "burst filled the whole
    /// sample interval" effect that single-window 1 Hz sampling
    /// suffers from. With `windowSize == 4` and a 500 ms internal
    /// cadence, the published value is the mean of the last 2 s
    /// of utilisation.
    ///
    /// Returns an empty array until the buffer holds at least one
    /// sample.
    func averagedSample() -> [Double] {
        guard let first = ringBuffer.first else { return [] }
        if ringBuffer.count == 1 { return first }
        let count = first.count
        var sums = Array(repeating: 0.0, count: count)
        for snapshot in ringBuffer {
            // Tolerate a hotplug-triggered length mismatch: if a
            // snapshot got captured under the old core count we
            // skip it rather than reading past its end.
            guard snapshot.count == count else { continue }
            for index in 0..<count {
                sums[index] += snapshot[index]
            }
        }
        let divisor = Double(ringBuffer.count)
        return sums.map { $0 / divisor }
    }

    /// Drops the cached baseline and rolling window so the next
    /// `sample()` re-arms. Called when the drill-down collapses,
    /// so a stale baseline doesn't produce a misleading first
    /// frame next time it expands.
    func reset() {
        previous = nil
        ringBuffer.removeAll(keepingCapacity: true)
    }

    /// Thin wrapper around `host_processor_info`. Returns `nil`
    /// when the syscall fails (extremely rare; documented only
    /// for boot-time races).
    private func readHostProcessorInfo() -> [CoreTicks]? {
        var processorCount = natural_t(0)
        var infoArray: processor_info_array_t?
        var infoCount = mach_msg_type_number_t(0)

        let kr = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &infoArray,
            &infoCount,
        )
        guard kr == KERN_SUCCESS, let infoArray else { return nil }

        // Always release the mach VM region the kernel handed
        // back, regardless of how this function returns.
        defer {
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            let address = vm_address_t(UInt(bitPattern: OpaquePointer(infoArray)))
            vm_deallocate(mach_task_self_, address, size)
        }

        // Each core contributes CPU_STATE_MAX (4) integer slots:
        // user, system, idle, nice — in that exact order per
        // <mach/processor_info.h>.
        let cores = Int(processorCount)
        let stride = Int(CPU_STATE_MAX)
        guard cores > 0, Int(infoCount) >= cores * stride else { return nil }

        var result: [CoreTicks] = []
        result.reserveCapacity(cores)
        let buffer = UnsafeBufferPointer(start: infoArray, count: Int(infoCount))
        for core in 0..<cores {
            let base = core * stride
            result.append(CoreTicks(
                user: UInt32(bitPattern: buffer[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: buffer[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: buffer[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: buffer[base + Int(CPU_STATE_NICE)]),
            ))
        }
        return result
    }
}
