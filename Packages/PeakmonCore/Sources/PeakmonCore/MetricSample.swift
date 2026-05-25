//
//  MetricSample.swift
//  PeakmonCore
//
//  Canonical metric data model. Every collector produces values that map
//  to this shape so the rest of the pipeline (Store, Scheduler, UI,
//  Storage) is metric-agnostic.
//

import Foundation

/// Identifies the kind of metric a sample represents.
///
/// The raw string is stable and used as the primary key when persisting
/// samples (see `PeakmonStorage`).
public enum MetricKind: String, Hashable, Codable, Sendable, CaseIterable {
    case cpuTotal = "cpu.total"
    case cpuUser = "cpu.user"
    case cpuSystem = "cpu.system"
    case memoryUsed = "memory.used"
    case memoryPressure = "memory.pressure"
    case batteryLevel = "battery.level"
    case batteryPowerSource = "battery.power_source"
    case batteryCycleCount = "battery.cycle_count"
    case batteryHealth = "battery.health"
    case batteryTimeRemaining = "battery.time_remaining"
    case diskUsed = "disk.used"
    case diskTotal = "disk.total"
    case diskReadRate = "disk.read_rate"
    case diskWriteRate = "disk.write_rate"
    case netInRate = "net.in_rate"
    case netOutRate = "net.out_rate"
    case gpuUtilization = "gpu.utilization"
    case powerCPU = "power.cpu"
    case powerGPU = "power.gpu"
    case powerDRAM = "power.dram"
    case powerDisplay = "power.display"
    case powerPackage = "power.package"
    case powerSystem = "power.system"
    case thermalCPU = "thermal.cpu"
    case thermalGPU = "thermal.gpu"
    case fanLeftRPM = "fan.left.rpm"
    case fanRightRPM = "fan.right.rpm"
}

/// Unit of measurement attached to a `MetricSample`.
///
/// Kept intentionally small for v0.1. Extend as new collectors land.
public enum MetricUnit: String, Hashable, Codable, Sendable {
    case percent
    case bytes
    case bytesPerSecond = "bytes_per_second"
    case count
    case ratio
    case watts
    case celsius
    case rpm
}

/// A single point-in-time observation produced by a `MetricCollector`.
///
/// `value` is always a `Double` so the UI / storage layers do not need to
/// dispatch on metric kind. Interpretation (e.g. percent vs bytes) is
/// driven by `unit`.
public struct MetricSample: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let kind: MetricKind
    public let unit: MetricUnit
    public let value: Double
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        kind: MetricKind,
        unit: MetricUnit,
        value: Double,
        timestamp: Date = .now,
    ) {
        self.id = id
        self.kind = kind
        self.unit = unit
        self.value = value
        self.timestamp = timestamp
    }
}
