//
//  ProcessSnapshot.swift
//  PeakmonCore
//
//  Immutable, value-typed snapshot of a single process's resource use
//  at a point in time. Produced by the process collector and consumed
//  by the dashboard's Top Processes card.
//
//  Kept deliberately small and Sendable so it crosses the
//  collector -> MainActor boundary cheaply.
//

import Foundation

/// One row in a "Top Processes" listing.
///
/// `cpuPercent` is the share of *one CPU core* the process consumed
/// across the most recent sampling interval — values can therefore
/// exceed 100% on multi-threaded processes. That convention matches
/// `top` and `Activity Monitor` and is the most directly useful number
/// for spotting a runaway process.
///
/// `memoryBytes` is resident set size (physical RAM footprint), the
/// same number Activity Monitor displays under "Memory".
public struct ProcessSnapshot: Sendable, Equatable, Identifiable {
    public let pid: Int32
    public let ppid: Int32
    public let name: String
    public let cpuPercent: Double
    public let memoryBytes: UInt64
    /// Absolute filesystem path to the executable as reported by
    /// `proc_pidpath`. Empty for processes the caller cannot inspect
    /// (cross-user without entitlements, kernel tasks). Carrying the
    /// path on the snapshot lets the dashboard's app-grouping pass
    /// resolve the owning `.app` bundle without a second syscall per
    /// PID at render time.
    public let path: String

    public var id: Int32 { pid }

    public init(
        pid: Int32,
        ppid: Int32 = 0,
        name: String,
        cpuPercent: Double,
        memoryBytes: UInt64,
        path: String = "",
    ) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.path = path
    }
}
