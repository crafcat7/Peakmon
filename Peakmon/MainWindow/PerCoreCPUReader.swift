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

    /// Computes per-core utilisation since the previous sample.
    /// Returns a value in 0...1 per logical CPU, or an empty
    /// array if no baseline exists yet.
    ///
    /// Algorithm
    ///   1. Ask the host for the current tick array.
    ///   2. For each core, subtract previous user+sys+idle+nice;
    ///      divide busy delta (user+sys) by total delta.
    ///   3. Stash the new snapshot for next time.
    func sample() -> [Double] {
        guard let current = readHostProcessorInfo() else {
            return previous == nil ? [] : Array(repeating: 0, count: previous?.count ?? 0)
        }
        defer { previous = current }

        guard let previous, previous.count == current.count else {
            return [] // first call, or core count changed (hotplug)
        }

        return zip(previous, current).map { prev, now in
            let totalDelta = now.total - prev.total
            guard totalDelta > 0 else { return 0 }
            let busyDelta = Double(now.user &- prev.user)
                + Double(now.system &- prev.system)
                + Double(now.nice &- prev.nice)
            return max(0, min(1, busyDelta / totalDelta))
        }
    }

    /// Drops the cached baseline so the next `sample()` re-arms.
    /// Called when the drill-down collapses, so a stale baseline
    /// doesn't produce a misleading first frame next time it
    /// expands.
    func reset() {
        previous = nil
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
