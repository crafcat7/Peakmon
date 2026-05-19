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
    public let name: String
    public let cpuPercent: Double
    public let memoryBytes: UInt64

    public var id: Int32 { pid }

    public init(
        pid: Int32,
        name: String,
        cpuPercent: Double,
        memoryBytes: UInt64,
    ) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}
