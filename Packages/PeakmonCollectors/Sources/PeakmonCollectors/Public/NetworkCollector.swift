//
//  NetworkCollector.swift
//  PeakmonCollectors
//
//  Collects system-wide network throughput (bytes/sec in/out) by
//  querying `sysctl(NET_RT_IFLIST2)` for each interface's `if_data64`
//  byte counters and diffing across calls. Loopback and tunnel
//  interfaces are excluded so the numbers reflect "real" traffic.
//

import Darwin
import Foundation
import PeakmonCore

public final class NetworkCollector: ResettableMetricCollector {
    public let identifier = "net.host"

    private let state = ThroughputState()

    public init() {}

    public func collect() async throws -> [MetricSample] {
        let totals = try Self.aggregateBytes()
        guard let rate = await state.observe(rx: totals.rx, tx: totals.tx) else {
            return []
        }
        let now = Date.now
        return [
            MetricSample(kind: .netInRate, unit: .bytesPerSecond, value: rate.rx, timestamp: now),
            MetricSample(kind: .netOutRate, unit: .bytesPerSecond, value: rate.tx, timestamp: now),
        ]
    }

    public func reset() async {
        await state.reset()
    }

    // MARK: - sysctl walk

    private static func aggregateBytes() throws -> (rx: UInt64, tx: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else {
            throw CollectorError.sysctlFailed(errno)
        }
        var buffer = [UInt8](repeating: 0, count: size)
        let rc = buffer.withUnsafeMutableBufferPointer { ptr in
            sysctl(&mib, u_int(mib.count), ptr.baseAddress, &size, nil, 0)
        }
        guard rc == 0 else { throw CollectorError.sysctlFailed(errno) }

        var rx: UInt64 = 0
        var tx: UInt64 = 0
        buffer.withUnsafeBufferPointer { raw in
            guard let base = raw.baseAddress else { return }
            var cursor = 0
            while cursor < size {
                let header = base.advanced(by: cursor)
                    .withMemoryRebound(to: if_msghdr.self, capacity: 1) { $0.pointee }
                let msgLen = Int(header.ifm_msglen)
                if header.ifm_type == RTM_IFINFO2 {
                    let if2 = base.advanced(by: cursor)
                        .withMemoryRebound(to: if_msghdr2.self, capacity: 1) { $0.pointee }
                    let flags = Int32(if2.ifm_flags)
                    let isLoopback = (flags & IFF_LOOPBACK) != 0
                    if !isLoopback, if2.ifm_data.ifi_type != UInt8(IFT_OTHER) {
                        rx &+= if2.ifm_data.ifi_ibytes
                        tx &+= if2.ifm_data.ifi_obytes
                    }
                }
                cursor += msgLen
            }
        }
        return (rx, tx)
    }
}

private actor ThroughputState {
    private var lastRx: UInt64 = 0
    private var lastTx: UInt64 = 0
    private var lastTimestamp: Date?

    func observe(rx: UInt64, tx: UInt64) -> (rx: Double, tx: Double)? {
        let now = Date()
        defer {
            lastRx = rx
            lastTx = tx
            lastTimestamp = now
        }
        guard let last = lastTimestamp else { return nil }
        let dt = now.timeIntervalSince(last)
        guard dt > 0 else { return nil }
        let dr = rx >= lastRx ? rx &- lastRx : 0
        let dw = tx >= lastTx ? tx &- lastTx : 0
        return (rx: Double(dr) / dt, tx: Double(dw) / dt)
    }

    func reset() {
        lastRx = 0
        lastTx = 0
        lastTimestamp = nil
    }
}
