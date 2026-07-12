//
//  ProcessCollector.swift
//  PeakmonCollectors
//
//  Enumerates running BSD processes via libproc and computes each
//  process's share of CPU across the most recent polling interval.
//  Designed to run on a slower cadence than the host-metric collectors
//  because walking ~500 PIDs and reading PROC_PIDTASKINFO for each is
//  measurably more expensive (10–50 ms) than a single
//  `host_statistics64` call.
//
//  Public API of PeakmonCollectors. No private/SPI usage; everything
//  is built on `libproc.h` + Mach time conversions.
//

import Darwin
import Foundation
import PeakmonCore

/// Walks `proc_listallpids` and emits a `ProcessSnapshot` per BSD
/// process, ranked descending by CPU usage over the interval since
/// the previous `collect()` call.
///
/// The first call after launch always returns an empty array because
/// no baseline exists yet to diff against — exactly the same pattern
/// `CPUCollector` uses.
///
/// `collect()` is intentionally *not* required to conform to
/// `MetricCollector` because the resulting data shape
/// (`[ProcessSnapshot]`) does not fit into the time-series
/// `[MetricSample]` model. Callers drive it from their own task at
/// whatever cadence makes sense (we use 2 s in production).
public final class ProcessCollector: Sendable {
    public let identifier = "process.libproc"

    /// Maximum number of processes returned per snapshot, or `nil`
    /// to return every process. The popover's Top Processes card
    /// historically capped this at 10 to keep the body short, but
    /// the main-window dashboard's full-width Processes panel wants
    /// the entire table so the user can scroll/sort the long tail,
    /// so the collector now defaults to "no cap" and lets consumers
    /// opt-in to truncation via `prefix(_:)` on the result.
    public let limit: Int?

    private let state = State()

    public init(limit: Int? = nil) {
        self.limit = limit
    }

    public func collect() async throws -> [ProcessSnapshot] {
        await state.collect(limit: limit)
    }

    public func reset() async {
        await state.reset()
    }

    // MARK: - libproc plumbing

    private struct Info: Sendable {
        let name: String
        let ppid: Int32
        let path: String
        let cpuTimeRaw: UInt64       // user + system, in mach time units
        let memoryBytes: UInt64
    }

    private struct ProcessStartTime: Equatable {
        let seconds: Int64
        let microseconds: Int64
    }

    /// Mach timebase used to convert raw `ptinfo_total_*` ticks into
    /// nanoseconds. Cached because it is constant per boot but the
    /// `mach_timebase_info` syscall is not free at 1 Hz × N processes.
    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    /// Snapshot the full PID table. `proc_listallpids` is the modern
    /// replacement for `proc_listpids(PROC_ALL_PIDS, ...)` and returns
    /// the active BSD pid set.
    static func pidCount(
        fromProcListAllPIDsReturn returnedCount: Int32,
        bufferCapacity: Int
    ) -> Int {
        guard returnedCount > 0, bufferCapacity > 0 else { return 0 }
        return min(Int(returnedCount), bufferCapacity)
    }

    private static func listPIDs(into buffer: inout [pid_t]) -> Int {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return 0 }
        // Add headroom because processes can appear between the two
        // calls; oversizing is fine, `proc_listallpids` clips to what
        // it actually wrote.
        let capacity = max(Int(needed) + 64, 256)
        if buffer.count < capacity {
            buffer = [pid_t](repeating: 0, count: capacity)
        }

        for attempt in 0 ..< 2 {
            let written = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
                let bytes = Int32(ptr.count * MemoryLayout<pid_t>.size)
                return proc_listallpids(ptr.baseAddress, bytes)
            }
            let count = pidCount(
                fromProcListAllPIDsReturn: written,
                bufferCapacity: buffer.count,
            )
            if count < buffer.count || attempt == 1 {
                return count
            }

            let growth = max(128, buffer.count / 2)
            buffer.append(contentsOf: repeatElement(pid_t(0), count: growth))
        }

        return 0
    }

    /// Per-PID lookup using `PROC_PIDTASKALLINFO`, which folds the
    /// task counters (`ptinfo`, formerly read via `PROC_PIDTASKINFO`)
    /// together with the BSD process info (`pbsd`) — most notably
    /// `pbi_ppid`, which the dashboard's app-grouping pass needs.
    /// Bundling both halves into a single syscall keeps the per-tick
    /// cost flat compared to the prior task-only call.
    ///
    /// The BSD command name is read from the same all-info blob to
    /// avoid an extra `proc_name` call per PID. `proc_pidpath` is
    /// still called separately because it has its own (larger) buffer
    /// and isn't part of the all-info blob.
    /// Failures are silently skipped — processes can exit between
    /// `listPIDs` and this call, and short-lived helpers regularly
    /// disappear under our feet.
    private static func readInfos(
        forPIDsIn pidBuffer: [pid_t],
        count pidCount: Int,
        pathBuffer: inout [CChar],
        pathCache: ProcessPathCache,
        into out: inout [Int32: Info]
    ) {
        out.removeAll(keepingCapacity: true)
        out.reserveCapacity(pidCount)

        if pathBuffer.count < 4096 {
            pathBuffer = [CChar](repeating: 0, count: 4096)
        }

        for index in 0 ..< pidCount {
            let pid = Int32(pidBuffer[index])
            guard pid > 0 else { continue }

            var info = proc_taskallinfo()
            let size = Int32(MemoryLayout<proc_taskallinfo>.size)
            let written = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, size)
            guard written == size else { continue }

            let name = Self.processName(fromBSDName: info.pbsd.pbi_name, pid: pid)
            let startTime = ProcessStartTime(
                seconds: Int64(info.pbsd.pbi_start_tvsec),
                microseconds: Int64(info.pbsd.pbi_start_tvusec),
            )

            // `proc_pidpath` returns the byte count on success, 0 on
            // failure (cross-user / kernel tasks). Empty path is a
            // valid state that downstream code already handles.
            let path = pathCache.path(for: pid, startTime: startTime) {
                Self.processPath(pid: pid, buffer: &pathBuffer)
            }

            out[pid] = Info(
                name: name,
                ppid: info.pbsd.pbi_ppid > 0
                    ? Int32(bitPattern: info.pbsd.pbi_ppid)
                    : 0,
                path: path,
                cpuTimeRaw: info.ptinfo.pti_total_user &+ info.ptinfo.pti_total_system,
                memoryBytes: info.ptinfo.pti_resident_size,
            )
        }
        pathCache.retain(knownBy: out)
    }

    private static func processPath(pid: Int32, buffer: inout [CChar]) -> String {
        let pathLen = buffer.withUnsafeMutableBufferPointer { ptr in
            proc_pidpath(pid, ptr.baseAddress, UInt32(ptr.count))
        }
        guard pathLen > 0 else { return "" }

        return buffer.withUnsafeBytes { raw in
            let byteCount = min(Int(pathLen), raw.count)
            let bytes = raw[..<byteCount]
            let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
            guard end > bytes.startIndex else { return "" }
            return String(decoding: bytes[bytes.startIndex..<end], as: UTF8.self)
        }
    }

    /// Best-effort human-readable name. `pbi_name` is the BSD
    /// command name (15-char limit), which matches what `top` and
    /// `ps` show and is already returned by `PROC_PIDTASKALLINFO`.
    /// If it is empty we fall back to "pid <n>" so the row is still
    /// identifiable.
    private static func processName<T>(fromBSDName pbiName: T, pid: Int32) -> String {
        let name = fixedCString(pbiName)
        if !name.isEmpty { return name }
        return "pid \(pid)"
    }

    private static func fixedCString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { raw in
            let end = raw.firstIndex(of: 0) ?? raw.endIndex
            guard end > raw.startIndex else { return "" }
            return String(decoding: raw[raw.startIndex..<end], as: UTF8.self)
        }
    }

    private static func fixedCString(_ buffer: [CChar]) -> String {
        buffer.withUnsafeBytes { raw in
            let end = raw.firstIndex(of: 0) ?? raw.endIndex
            guard end > raw.startIndex else { return "" }
            return String(decoding: raw[raw.startIndex..<end], as: UTF8.self)
        }
    }

    private final class ProcessPathCache {
        private struct Entry {
            let startTime: ProcessStartTime
            let path: String
        }

        private let lock = NSLock()
        private var storage: [Int32: Entry] = [:]

        func path(for pid: Int32, startTime: ProcessStartTime, load: () -> String) -> String {
            lock.lock()
            if let cached = storage[pid], cached.startTime == startTime {
                lock.unlock()
                return cached.path
            }
            lock.unlock()

            let path = load()

            lock.lock()
            storage[pid] = Entry(startTime: startTime, path: path)
            lock.unlock()

            return path
        }

        func retain(knownBy infos: [Int32: Info]) {
            lock.lock()
            storage = storage.filter { infos[$0.key] != nil }
            lock.unlock()
        }

        func clear() {
            lock.lock()
            storage.removeAll(keepingCapacity: true)
            lock.unlock()
        }
    }

    /// Holds the previous tick's per-PID `Info` plus the timestamp at
    /// which it was captured. An actor so concurrent `collect()`
    /// invocations remain safe even though we never expect more than
    /// one outstanding call in practice.
    private actor State {
        private var previousSampledAt: Date?
        private var previousInfos: [Int32: Info] = [:]
        private var currentInfos: [Int32: Info] = [:]
        private var pidBuffer: [pid_t] = []
        private var pathBuffer = [CChar](repeating: 0, count: 4096)
        private var snapshotBuffer: [ProcessSnapshot] = []
        private let pathCache = ProcessPathCache()

        func collect(limit: Int?) -> [ProcessSnapshot] {
            let now = Date.now
            let pidCount = ProcessCollector.listPIDs(into: &pidBuffer)
            ProcessCollector.readInfos(
                forPIDsIn: pidBuffer,
                count: pidCount,
                pathBuffer: &pathBuffer,
                pathCache: pathCache,
                into: &currentInfos,
            )

            guard let sampledAt = previousSampledAt, sampledAt < now else {
                rotateBaseline(sampledAt: now)
                return []
            }

            let elapsedNanos = now.timeIntervalSince(sampledAt) * 1_000_000_000
            guard elapsedNanos > 0 else {
                rotateBaseline(sampledAt: now)
                return []
            }

            let timebase = ProcessCollector.timebase
            snapshotBuffer.removeAll(keepingCapacity: true)
            snapshotBuffer.reserveCapacity(currentInfos.count)

            for (pid, info) in currentInfos {
                guard let prev = previousInfos[pid] else { continue }
                // total_user + total_system are in mach_absolute_time units
                // (subtract previous, convert via timebase to nanoseconds).
                let deltaMachTime = (info.cpuTimeRaw &- prev.cpuTimeRaw)
                let deltaNanos =
                    Double(deltaMachTime) * Double(timebase.numer) / Double(timebase.denom)
                let cpuPercent = (deltaNanos / elapsedNanos) * 100
                snapshotBuffer.append(ProcessSnapshot(
                    pid: pid,
                    ppid: info.ppid,
                    name: info.name,
                    cpuPercent: max(cpuPercent, 0),
                    memoryBytes: info.memoryBytes,
                    path: info.path,
                ))
            }

            snapshotBuffer.sort { $0.cpuPercent > $1.cpuPercent }
            if let limit, snapshotBuffer.count > limit {
                snapshotBuffer.removeLast(snapshotBuffer.count - limit)
            }

            let snapshots = Array(snapshotBuffer)
            snapshotBuffer.removeAll(keepingCapacity: true)
            rotateBaseline(sampledAt: now)
            return snapshots
        }

        func reset() {
            previousSampledAt = nil
            previousInfos.removeAll(keepingCapacity: true)
            currentInfos.removeAll(keepingCapacity: true)
            snapshotBuffer.removeAll(keepingCapacity: true)
            pathCache.clear()
        }

        private func rotateBaseline(sampledAt: Date) {
            swap(&previousInfos, &currentInfos)
            currentInfos.removeAll(keepingCapacity: true)
            previousSampledAt = sampledAt
        }
    }
}
