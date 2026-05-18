//
//  MemoryCollector.swift
//  PeakmonCollectors
//
//  Reports memory used (bytes) and memory pressure (% of physical RAM)
//  using `host_statistics64(HOST_VM_INFO64)`. Matches the "App Memory"
//  style accounting: active + wired + compressed.
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
        let pageSize = Self.pageSize()
        let usedPages = UInt64(stats.active_count)
            + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)
        let usedBytes = Double(usedPages) * Double(pageSize)
        let pressure = totalBytes > 0 ? (usedBytes / totalBytes) * 100.0 : 0
        let now = Date.now
        return [
            MetricSample(kind: .memoryUsed, unit: .bytes, value: usedBytes, timestamp: now),
            MetricSample(kind: .memoryPressure, unit: .percent, value: pressure, timestamp: now),
        ]
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
}
