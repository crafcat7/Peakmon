//
//  DiskCollector.swift
//  PeakmonCollectors
//
//  Collects disk usage of the root volume (via `statfs("/")`) plus
//  system-wide disk read/write throughput (via IOKit's
//  `IOBlockStorageDriver` statistics). Throughput is computed by
//  diffing the monotonically increasing byte counters between two
//  successive `collect()` calls. The first call seeds the baseline and
//  returns only the static usage samples.
//

import Darwin
import Foundation
import IOKit
import PeakmonCore

public final class DiskCollector: ResettableMetricCollector {
    public let identifier = "disk.host"

    private let state = ThroughputState()

    public init() {}

    public func collect() async throws -> [MetricSample] {
        var samples: [MetricSample] = []

        if let (used, total) = Self.rootVolumeUsage() {
            samples.append(MetricSample(kind: .diskUsed, unit: .bytes, value: used))
            samples.append(MetricSample(kind: .diskTotal, unit: .bytes, value: total))
        }

        let totals = Self.aggregateBlockStorageStats()
        if let rate = await state.observe(read: totals.read, write: totals.write) {
            samples.append(MetricSample(
                kind: .diskReadRate,
                unit: .bytesPerSecond,
                value: rate.read,
            ))
            samples.append(MetricSample(
                kind: .diskWriteRate,
                unit: .bytesPerSecond,
                value: rate.write,
            ))
        }
        return samples
    }

    public func reset() async {
        await state.reset()
    }

    // MARK: - statfs

    private static func rootVolumeUsage() -> (used: Double, total: Double)? {
        var stats = statfs()
        guard statfs("/", &stats) == 0 else { return nil }
        let blockSize = Double(stats.f_bsize)
        let total = Double(stats.f_blocks) * blockSize
        let free = Double(stats.f_bavail) * blockSize
        return (used: max(0, total - free), total: total)
    }

    // MARK: - IOKit aggregate throughput

    private static func aggregateBlockStorageStats() -> (read: UInt64, write: UInt64) {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else {
            return (0, 0)
        }
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }

        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var unmanagedProps: Unmanaged<CFMutableDictionary>?
            let propsKR = IORegistryEntryCreateCFProperties(
                service,
                &unmanagedProps,
                kCFAllocatorDefault,
                0,
            )
            guard propsKR == KERN_SUCCESS,
                  let props = unmanagedProps?.takeRetainedValue() as? [String: Any],
                  let stats = props["Statistics"] as? [String: Any] else { continue }

            if let read = stats["Bytes (Read)"] as? UInt64 {
                totalRead &+= read
            }
            if let write = stats["Bytes (Write)"] as? UInt64 {
                totalWrite &+= write
            }
        }
        return (totalRead, totalWrite)
    }
}

/// Holds the last cumulative byte counters + timestamp so we can diff
/// successive snapshots into bytes-per-second.
private actor ThroughputState {
    private var lastRead: UInt64 = 0
    private var lastWrite: UInt64 = 0
    private var lastTimestamp: Date?

    func observe(read: UInt64, write: UInt64) -> (read: Double, write: Double)? {
        let now = Date()
        defer {
            lastRead = read
            lastWrite = write
            lastTimestamp = now
        }
        guard let last = lastTimestamp else { return nil }
        let dt = now.timeIntervalSince(last)
        guard dt > 0 else { return nil }
        let dr = read >= lastRead ? read &- lastRead : 0
        let dw = write >= lastWrite ? write &- lastWrite : 0
        return (read: Double(dr) / dt, write: Double(dw) / dt)
    }

    func reset() {
        lastRead = 0
        lastWrite = 0
        lastTimestamp = nil
    }
}
