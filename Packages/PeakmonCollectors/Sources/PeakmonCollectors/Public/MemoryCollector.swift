//
//  MemoryCollector.swift
//  PeakmonCollectors
//
//  Reports memory used / pressure plus the three depth metrics the
//  Activity Monitor "Memory" tab surfaces: wired (kernel-pinned),
//  compressed (live pages held in the compressor), and swap-used
//  (bytes paged out to the swap files). Used + pressure come from
//  `host_statistics64(HOST_VM_INFO64)`; swap comes from
//  `sysctl(CTL_VM, VM_SWAPUSAGE)` which returns an `xsw_usage`
//  struct populated by the kernel. The discrete VM-pressure level
//  (1 = normal, 2 = warning, 4 = urgent, 8 = critical) is read from
//  the `kern.memorystatus_vm_pressure_level` sysctl so dashboard
//  surfaces can match the same green/yellow/red bands Activity
//  Monitor's pressure graph uses.
//

import Darwin
import Foundation
import PeakmonCore

public final class MemoryCollector: MetricCollector {
    public let identifier = "memory.host"

    private let totalBytes: Double

    public init() {
        totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
    }

    public func collect() async throws -> [MetricSample] {
        let stats = try Self.readVMStats()
        let pageSize = Double(Self.pageSize())
        let wiredBytes = Double(stats.wire_count) * pageSize
        let compressedBytes = Double(stats.compressor_page_count) * pageSize
        let activeBytes = Double(stats.active_count) * pageSize
        let usedBytes = activeBytes + wiredBytes + compressedBytes
        let pressure = totalBytes > 0 ? (usedBytes / totalBytes) * 100.0 : 0
        let swapBytes = Self.readSwapUsedBytes()
        let pressureLevel = Self.readPressureLevel()
        let now = Date.now

        var samples: [MetricSample] = [
            MetricSample(kind: .memoryUsed, unit: .bytes, value: usedBytes, timestamp: now),
            MetricSample(kind: .memoryPressure, unit: .percent, value: pressure, timestamp: now),
            MetricSample(kind: .memoryWired, unit: .bytes, value: wiredBytes, timestamp: now),
            MetricSample(
                kind: .memoryCompressed,
                unit: .bytes,
                value: compressedBytes,
                timestamp: now,
            ),
        ]
        if let swapBytes {
            samples.append(MetricSample(
                kind: .memorySwapUsed,
                unit: .bytes,
                value: swapBytes,
                timestamp: now,
            ))
        }
        if let pressureLevel {
            samples.append(MetricSample(
                kind: .memoryPressureLevel,
                unit: .count,
                value: Double(pressureLevel),
                timestamp: now,
            ))
        }
        return samples
    }

    // MARK: - Private

    private static func readVMStats() throws -> vm_statistics64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride,
        )
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics64(
                    mach_host_self(),
                    HOST_VM_INFO64,
                    reboundPtr,
                    &count,
                )
            }
        }
        guard kr == KERN_SUCCESS else {
            throw CollectorError.machCallFailed(kr)
        }
        return stats
    }

    private static func pageSize() -> vm_size_t {
        var size: vm_size_t = 0
        host_page_size(mach_host_self(), &size)
        return size == 0 ? vm_size_t(getpagesize()) : size
    }

    /// Reads `xsw_usage.xsu_used` (bytes currently on swap) via
    /// `sysctl(CTL_VM, VM_SWAPUSAGE)`. Returns `nil` if the kernel
    /// declines the call (rare; would also mean swap is unavailable).
    private static func readSwapUsedBytes() -> Double? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        var mib: [Int32] = [CTL_VM, VM_SWAPUSAGE]
        let result = mib.withUnsafeMutableBufferPointer { mibPtr -> Int32 in
            sysctl(mibPtr.baseAddress, 2, &usage, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        return Double(usage.xsu_used)
    }

    /// Reads the discrete VM-pressure level from
    /// `kern.memorystatus_vm_pressure_level`. The XNU kernel exposes
    /// the same enum it dispatches `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`
    /// events from:
    ///
    ///   1 = normal, 2 = warning, 4 = urgent, 8 = critical.
    ///
    /// These are the buckets Activity Monitor's pressure graph maps
    /// to green / yellow / red bands, so surfacing the raw value lets
    /// dashboard UI match what the user sees in Activity Monitor
    /// instead of guessing from an occupancy percentage.
    ///
    /// Returns `nil` if the sysctl is unavailable (none of the
    /// supported macOS versions actually decline it, but stay
    /// defensive so the rest of the sample batch still ships).
    private static func readPressureLevel() -> Int? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname(
            "kern.memorystatus_vm_pressure_level",
            &level,
            &size,
            nil,
            0,
        )
        guard result == 0 else { return nil }
        return Int(level)
    }
}
