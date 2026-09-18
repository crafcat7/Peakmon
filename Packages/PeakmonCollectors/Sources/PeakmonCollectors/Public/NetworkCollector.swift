//
//  NetworkCollector.swift
//  PeakmonCollectors
//
//  Collects system-wide network throughput (bytes/sec in/out) by
//  querying `sysctl(NET_RT_IFLIST2)` for each interface's `if_data64`
//  byte counters and diffing across calls. Only physical interfaces on the
//  active external path are included so proxy/tunnel and side-channel
//  interfaces do not change the measurement scope or get counted twice.
//

import Darwin
import Foundation
import Network
import PeakmonCore

public final class NetworkCollector: ResettableMetricCollector {
    public let identifier = "net.host"

    private let state = ThroughputState()
    private let interfaceScope = ExternalInterfaceScope()

    public init() {}

    public func collect() async throws -> [MetricSample] {
        let interfaceIndices = await interfaceScope.currentInterfaceIndices()
        let totals = try Self.aggregateBytes(interfaceIndices: interfaceIndices)
        guard let rate = await state.observe(
            rx: totals.rx,
            tx: totals.tx,
            scope: interfaceIndices,
        ) else {
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

    private static func aggregateBytes(
        interfaceIndices: Set<Int>,
    ) throws -> (rx: UInt64, tx: UInt64) {
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
                    let isPhysical = if2.ifm_data.ifi_type == UInt8(IFT_ETHER)
                        || if2.ifm_data.ifi_type == UInt8(IFT_CELLULAR)
                    guard !isLoopback,
                          isPhysical,
                          interfaceIndices.contains(Int(if2.ifm_index))
                    else {
                        cursor += msgLen
                        continue
                    }
                    rx &+= if2.ifm_data.ifi_ibytes
                    tx &+= if2.ifm_data.ifi_obytes
                }
                cursor += msgLen
            }
        }
        return (rx, tx)
    }
}

/// Resolves the physical interface(s) used by the current external path.
///
/// `NET_RT_IFLIST2` exposes counters for every interface, including bridge,
/// AWDL, LLW, and tunnel devices. `NWPathMonitor` hides a VPN/TUN hop and
/// reports the underlying Wi-Fi/Ethernet/cellular interface instead, which is
/// the scope we want for a system network-throughput metric.
private final class ExternalInterfaceScope: @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.crafcat7.Peakmon.network-path")
    private let lock = NSLock()
    private var latestIndices: Set<Int> = []
    private var lastGoodIndices: Set<Int> = []

    init() {
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            self?.record(path: path)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    /// The first path callback is asynchronous. Wait briefly so the first
    /// collector sample normally starts with the real path scope, while still
    /// retaining a conservative physical-interface fallback for offline
    /// startup and tests.
    func currentInterfaceIndices() async -> Set<Int> {
        for _ in 0..<10 {
            let snapshot = self.snapshot()
            if !snapshot.latest.isEmpty {
                return snapshot.latest
            }
            if !snapshot.lastGood.isEmpty {
                return snapshot.lastGood
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        let fallback = Self.fallbackInterfaceIndices()
        if !fallback.isEmpty {
            remember(fallback)
        }
        return fallback
    }

    private func remember(_ indices: Set<Int>) {
        lock.lock()
        latestIndices = indices
        lastGoodIndices = indices
        lock.unlock()
    }

    private func record(path: NWPath) {
        let indices = Self.externalInterfaceIndices(from: path)
        lock.lock()
        latestIndices = indices
        if !indices.isEmpty {
            lastGoodIndices = indices
        }
        lock.unlock()
    }

    private func snapshot() -> (latest: Set<Int>, lastGood: Set<Int>) {
        lock.lock()
        defer { lock.unlock() }
        return (latestIndices, lastGoodIndices)
    }

    private static func externalInterfaceIndices(from path: NWPath) -> Set<Int> {
        guard path.status == .satisfied else { return [] }
        return Set(path.availableInterfaces.compactMap { interface in
            guard isExternalInterface(interface),
                  path.usesInterfaceType(interface.type)
            else { return nil }
            return interface.index
        })
    }

    private static func isExternalInterface(_ interface: NWInterface) -> Bool {
        let isExternalType: Bool
        switch interface.type {
        case .wifi, .wiredEthernet, .cellular:
            isExternalType = true
        default:
            isExternalType = false
        }
        return isExternalType && !isVirtualInterfaceName(interface.name)
    }

    private static func fallbackInterfaceIndices() -> Set<Int> {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { return [] }
        defer { freeifaddrs(addresses) }

        var indices: Set<Int> = []
        var cursor = addresses
        while let address = cursor {
            let entry = address.pointee
            guard let rawName = entry.ifa_name else {
                cursor = entry.ifa_next
                continue
            }
            let name = String(cString: rawName)
            let flags = entry.ifa_flags
            let requiredFlags = UInt32(IFF_UP | IFF_RUNNING)
            let isUpAndRunning = (flags & requiredFlags) == requiredFlags
            let isPhysicalName = name.hasPrefix("en") || name.hasPrefix("pdp_ip")
            guard isUpAndRunning, isPhysicalName, !isVirtualInterfaceName(name) else {
                cursor = entry.ifa_next
                continue
            }
            let index = if_nametoindex(rawName)
            if index != 0 {
                indices.insert(Int(index))
            }
            cursor = entry.ifa_next
        }
        return indices
    }

    private static func isVirtualInterfaceName(_ name: String) -> Bool {
        ["awdl", "llw", "anpi", "bridge", "utun", "lo"].contains {
            name.hasPrefix($0)
        }
    }
}

private actor ThroughputState {
    private var lastRx: UInt64 = 0
    private var lastTx: UInt64 = 0
    private var lastTimestamp: Date?
    private var lastScope: Set<Int>?

    func observe(rx: UInt64, tx: UInt64, scope: Set<Int>) -> (rx: Double, tx: Double)? {
        let now = Date()
        defer {
            lastRx = rx
            lastTx = tx
            lastTimestamp = now
            lastScope = scope
        }
        guard let last = lastTimestamp, lastScope == scope else { return nil }
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
        lastScope = nil
    }
}
