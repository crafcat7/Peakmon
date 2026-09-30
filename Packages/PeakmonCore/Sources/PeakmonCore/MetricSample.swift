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
    /// Historical raw key. The value has always been used / physical memory,
    /// while actual pressure state is stored in `memoryPressureLevel`.
    case memoryPressure = "memory.pressure"
    case memoryPressureLevel = "memory.pressure_level"
    case memoryWired = "memory.wired"
    case memoryCompressed = "memory.compressed"
    case memorySwapUsed = "memory.swap_used"
    case batteryLevel = "battery.level"
    case batteryPowerSource = "battery.power_source"
    case batteryCycleCount = "battery.cycle_count"
    case batteryHealth = "battery.health"
    case batteryTimeRemaining = "battery.time_remaining"
    case batteryTemperature = "battery.temperature"
    case diskUsed = "disk.used"
    case diskTotal = "disk.total"
    case diskReadRate = "disk.read_rate"
    case diskWriteRate = "disk.write_rate"
    case netInRate = "net.in_rate"
    case netOutRate = "net.out_rate"
    case gpuUtilization = "gpu.utilization"
    case gpuMemoryInUse = "gpu.memory_in_use"
    case powerCPU = "power.cpu"
    case powerCPUSupply = "power.cpu.supply"
    case powerGPU = "power.gpu"
    case powerGPUCore = "power.gpu.core"
    case powerGPUCommandStreamer = "power.gpu.cs"
    case powerGPUSRAM = "power.gpu.sram"
    case powerDRAM = "power.dram"
    case powerDisplay = "power.display"
    // SMC supply measurements have different scopes from Energy Model rails.
    case powerDRAMSupply = "power.dram.supply"
    case powerDisplayBacklight = "power.display.backlight"
    case powerGPUClusters = "power.gpu.clusters"
    case powerGPUShared = "power.gpu.shared"
    case powerPackage = "power.package"
    case powerSystem = "power.system"
    case thermalCPU = "thermal.cpu"
    case thermalGPU = "thermal.gpu"
    case fanLeftRPM = "fan.left.rpm"
    case fanRightRPM = "fan.right.rpm"

    /// Semantic spelling for the legacy persisted `memory.pressure` key.
    /// Keeping one raw value preserves existing history and saved settings.
    public static var memoryUsedPercent: MetricKind { .memoryPressure }
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
/// driven by `unit`. Only available samples represent measured values.
public struct MetricSample: Hashable, Codable, Sendable, Identifiable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, unit, value, timestamp, isAvailable
    }

    public let id: UUID
    public let kind: MetricKind
    public let unit: MetricUnit
    public let value: Double
    public let timestamp: Date
    public let isAvailable: Bool

    public init(
        id: UUID = UUID(),
        kind: MetricKind,
        unit: MetricUnit,
        value: Double,
        timestamp: Date = .now,
        isAvailable: Bool = true,
    ) {
        self.id = id
        self.kind = kind
        self.unit = unit
        self.value = value
        self.timestamp = timestamp
        self.isAvailable = isAvailable
    }

    /// Invalidates a metric's current reading without recording a fake zero.
    public static func unavailable(
        kind: MetricKind,
        unit: MetricUnit,
        timestamp: Date = .now,
    ) -> MetricSample {
        MetricSample(kind: kind, unit: unit, value: 0, timestamp: timestamp, isAvailable: false)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(MetricKind.self, forKey: .kind)
        unit = try container.decode(MetricUnit.self, forKey: .unit)
        value = try container.decode(Double.self, forKey: .value)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        isAvailable = try container.decodeIfPresent(Bool.self, forKey: .isAvailable) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(unit, forKey: .unit)
        try container.encode(value, forKey: .value)
        try container.encode(timestamp, forKey: .timestamp)
        if !isAvailable {
            try container.encode(false, forKey: .isAvailable)
        }
    }
}
