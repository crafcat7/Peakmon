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
public final class ProcessCollector {
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
    private let pathCache = ProcessPathCache()

    public init(limit: Int? = nil) {
        self.limit = limit
    }

    public func collect() async throws -> [ProcessSnapshot] {
        let now = Date.now
        let pids = try Self.listPIDs()
        let infos = readInfos(for: pids)

        let previous = await state.swap(infos: infos, at: now)
        guard let previous, previous.sampledAt < now else {
            // First sample or non-monotonic clock — nothing to diff.
            return []
        }

        let elapsedNanos = now.timeIntervalSince(previous.sampledAt) * 1_000_000_000
        guard elapsedNanos > 0 else { return [] }

        let timebase = Self.timebase
        var snapshots: [ProcessSnapshot] = []
        snapshots.reserveCapacity(infos.count)

        for (pid, info) in infos {
            guard let prev = previous.infos[pid] else { continue }
            // total_user + total_system are in mach_absolute_time units
            // (subtract previous, convert via timebase to nanoseconds).
            let deltaMachTime = (info.cpuTimeRaw &- prev.cpuTimeRaw)
            let deltaNanos =
                Double(deltaMachTime) * Double(timebase.numer) / Double(timebase.denom)
            let cpuPercent = (deltaNanos / elapsedNanos) * 100
            snapshots.append(ProcessSnapshot(
                pid: pid,
                ppid: info.ppid,
                name: info.name,
                cpuPercent: max(cpuPercent, 0),
                memoryBytes: info.memoryBytes,
                path: info.path,
            ))
        }

        snapshots.sort { $0.cpuPercent > $1.cpuPercent }
        if let limit, snapshots.count > limit {
            snapshots.removeLast(snapshots.count - limit)
        }
        return snapshots
    }

    public func reset() async {
        await state.reset()
        pathCache.clear()
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
    private static func listPIDs() throws -> [Int32] {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return [] }
        // Add headroom because processes can appear between the two
        // calls; oversizing is fine, `proc_listallpids` clips to what
        // it actually wrote.
        let capacity = Int(needed) + 64
        var buffer = [pid_t](repeating: 0, count: capacity)
        let written = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            let bytes = Int32(ptr.count * MemoryLayout<pid_t>.size)
            return proc_listallpids(ptr.baseAddress, bytes)
        }
        guard written > 0 else { return [] }
        let count = Int(written) / MemoryLayout<pid_t>.size
        return Array(buffer.prefix(count)).filter { $0 > 0 }
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
    private func readInfos(for pids: [Int32]) -> [Int32: Info] {
        var out: [Int32: Info] = [:]
        out.reserveCapacity(pids.count)

        var pathBuffer = [CChar](repeating: 0, count: 4096)

        for pid in pids {
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
        pathCache.retain(pids: Set(out.keys))
        return out
    }

    private static func processPath(pid: Int32, buffer: inout [CChar]) -> String {
        let pathLen = buffer.withUnsafeMutableBufferPointer { ptr in
            proc_pidpath(pid, ptr.baseAddress, UInt32(ptr.count))
        }
        return pathLen > 0 ? fixedCString(buffer) : ""
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

    private final class ProcessPathCache: @unchecked Sendable {
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

        func retain(pids: Set<Int32>) {
            lock.lock()
            storage = storage.filter { pids.contains($0.key) }
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
        struct Snapshot {
            let infos: [Int32: Info]
            let sampledAt: Date
        }

        private var previous: Snapshot?

        func swap(infos: [Int32: Info], at sampledAt: Date) -> Snapshot? {
            let outgoing = previous
            previous = Snapshot(infos: infos, sampledAt: sampledAt)
            return outgoing
        }

        func reset() {
            previous = nil
        }
    }
}
