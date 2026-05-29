//
//  PerCoreCPUReader.swift
//  Peakmon
//
//  Mach-level per-core CPU usage helper. The MetricsStore tracks
//  aggregate CPU only; this fills in per-core utilisation for the
//  CPU card without expanding the MetricKind enum or the scheduler
//  payload.
//
//  `host_processor_info(_, PROCESSOR_CPU_LOAD_INFO, …)` returns
//  `[user, system, idle, nice]` ticks-since-boot per logical CPU.
//  Sampling twice, diffing busy (user+sys) vs total, and dividing
//  gives a percentage — the same approach as `top` / Activity
//  Monitor. The previous tick is cached so each `sample()` returns
//  instantaneous deltas; the first call returns [] (no baseline).
//
//  Kept out of MetricsStore because the data is only used by the
//  CPU card and runs at that card's own 1 Hz cadence — no work
//  happens while it's off-screen.
//

import Darwin
import Foundation
import MachO
import Darwin.Mach

/// Per-core utilisation reader. `@MainActor` because its only
/// consumer (`DashboardCPUCard`) is, and the mach calls are cheap.
@MainActor
final class PerCoreCPUReader {
    /// Per-core tick counts from the previous `sample()`; `nil`
    /// until the first reading.
    private var previous: [CoreTicks]?

    /// Rolling window of the last `windowSize` instantaneous per-core
    /// arrays; `averagedSample()` means them so a single burst-filled
    /// window doesn't binarise the UI.
    private var ringBuffer: [[Double]] = []

    /// Rolling-average window length. Four samples × the caller's
    /// 500 ms internal cadence ≈ a 2 s smoothing window published at
    /// 1 Hz.
    private let windowSize = 4

    /// CPU topology (E-core / P-core split), read once from sysctl.
    let topology: Topology = .detect()

    /// Apple silicon perf-level topology. `host_processor_info`
    /// returns cores in sysctl order (E-cores then P-cores);
    /// `firstPCoreIndex` marks the boundary for the bar chart.
    struct Topology {
        /// Efficiency cores; 0 on Intel / no-E-cluster machines (all
        /// cores then render as P-cores).
        let efficiencyCores: Int
        /// Number of performance cores.
        let performanceCores: Int

        /// Index of the first P-core (== `efficiencyCores`).
        var firstPCoreIndex: Int { efficiencyCores }

        /// Total logical core count (E + P).
        var totalCores: Int { efficiencyCores + performanceCores }

        /// Perf-level breakdown from sysctl. On Apple silicon
        /// `hw.perflevel0` is the performance cluster (level 0 =
        /// highest perf) and `hw.perflevel1` the efficiency cluster.
        /// On Intel both are absent → 0 / `hw.logicalcpu`, collapsing
        /// to one P-band.
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

        /// Sum of all four channels — the utilisation denominator.
        /// Double so the subtraction in the delta can't underflow if
        /// the kernel resets a counter (rare, e.g. CPU hotplug).
        var total: Double {
            Double(user) + Double(system) + Double(idle) + Double(nice)
        }
    }

    /// Computes per-core utilisation since the previous sample,
    /// pushes it into the ring buffer, and returns the instantaneous
    /// value. Most UI callers want `averagedSample()`.
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

    /// Per-core mean of the rolling window — smooths over the binary
    /// "burst filled the whole interval" effect of single-window 1 Hz
    /// sampling. Empty until the buffer holds a sample.
    func averagedSample() -> [Double] {
        guard let first = ringBuffer.first else { return [] }
        if ringBuffer.count == 1 { return first }
        let count = first.count
        var sums = Array(repeating: 0.0, count: count)
        for snapshot in ringBuffer {
            // Skip a hotplug-length mismatch rather than read past
            // a snapshot captured under the old core count.
            guard snapshot.count == count else { continue }
            for index in 0..<count {
                sums[index] += snapshot[index]
            }
        }
        let divisor = Double(ringBuffer.count)
        return sums.map { $0 / divisor }
    }

    /// Drops the baseline and window so the next `sample()` re-arms.
    /// Called on drill-down collapse so a stale baseline doesn't
    /// produce a misleading first frame on re-expand.
    func reset() {
        previous = nil
        ringBuffer.removeAll(keepingCapacity: true)
    }

    /// Thin wrapper around `host_processor_info`; `nil` on failure
    /// (extremely rare, boot-time races only).
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
