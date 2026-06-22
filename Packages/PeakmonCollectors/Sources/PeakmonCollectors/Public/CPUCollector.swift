//
//  CPUCollector.swift
//  PeakmonCollectors
//
//  Reports system-wide CPU utilization (% of total host capacity) using
//  Mach `host_statistics64(HOST_CPU_LOAD_INFO)`. Uses the canonical
//  technique of diffing two snapshots so the result reflects the
//  interval between calls rather than uptime averages.
//
//  Public API of PeakmonCollectors — no private/SPI usage.
//

import Darwin
import Foundation
import PeakmonCore

/// Samples total / user / system CPU utilization for the host.
///
/// The collector keeps the previous tick snapshot inside an internal
/// actor so concurrent calls remain safe, then computes deltas to derive
/// percentages.
public final class CPUCollector: ResettableMetricCollector {
    public let identifier = "cpu.host"

    private let state = SnapshotState()

    public init() {}

    public func collect() async throws -> [MetricSample] {
        let snapshot = try Self.readSnapshot()
        let now = Date.now
        guard let previous = await state.swap(snapshot) else {
            // First call after launch: no baseline to diff against yet.
            return []
        }

        let deltaUser = Double(snapshot.user &- previous.user)
        let deltaSystem = Double(snapshot.system &- previous.system)
        let deltaIdle = Double(snapshot.idle &- previous.idle)
        let deltaNice = Double(snapshot.nice &- previous.nice)
        let total = deltaUser + deltaSystem + deltaIdle + deltaNice
        guard total > 0 else { return [] }

        let userPercent = (deltaUser + deltaNice) / total * 100.0
        let systemPercent = deltaSystem / total * 100.0
        let totalPercent = userPercent + systemPercent

        return [
            MetricSample(kind: .cpuTotal, unit: .percent, value: totalPercent, timestamp: now),
            MetricSample(kind: .cpuUser, unit: .percent, value: userPercent, timestamp: now),
            MetricSample(kind: .cpuSystem, unit: .percent, value: systemPercent, timestamp: now),
        ]
    }

    public func reset() async {
        await state.reset()
    }

    // MARK: - Private

    private struct Snapshot {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    private actor SnapshotState {
        private var previous: Snapshot?
        func swap(_ new: Snapshot) -> Snapshot? {
            let old = previous
            previous = new
            return old
        }

        func reset() {
            previous = nil
        }
    }

    private static func readSnapshot() throws -> Snapshot {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride,
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics64(
                    mach_host_self(),
                    HOST_CPU_LOAD_INFO,
                    reboundPtr,
                    &count,
                )
            }
        }
        guard kr == KERN_SUCCESS else {
            throw CollectorError.machCallFailed(kr)
        }
        // cpu_ticks is a tuple of 4 natural_t (UInt32): user, system, idle, nice.
        return Snapshot(
            user: info.cpu_ticks.0,
            system: info.cpu_ticks.1,
            idle: info.cpu_ticks.2,
            nice: info.cpu_ticks.3,
        )
    }
}

/// Errors emitted by the public collectors in this module.
public enum CollectorError: Error, Sendable {
    case machCallFailed(kern_return_t)
    case sysctlFailed(Int32)
}
