//
//  BatteryPowerSource.swift
//  PeakmonCore
//
//  Encodes the current power-source state of the host as a numeric
//  metric value so it can flow through the existing `MetricSample`
//  pipeline without introducing a parallel transport channel.
//
//  Mapping:
//    0 = on battery (discharging)
//    1 = AC plugged in and charging
//    2 = AC plugged in, battery full / not charging
//

import Foundation

public enum BatteryPowerSource: Int, Sendable, Hashable, Codable, CaseIterable {
    case onBattery = 0
    case charging = 1
    case acPlugged = 2

    /// Decode from the `Double` value carried inside a
    /// `MetricSample(kind: .batteryPowerSource, ...)`. Non-integer or
    /// out-of-range inputs fall back to `.onBattery` so the UI always
    /// has a sensible default.
    public init(metricValue: Double) {
        let rounded = Int(metricValue.rounded())
        self = BatteryPowerSource(rawValue: rounded) ?? .onBattery
    }

    public var metricValue: Double { Double(rawValue) }

    /// Short human-readable label shown alongside the battery
    /// percentage in cards and the status bar.
    public var displayLabel: String {
        switch self {
        case .onBattery: "On Battery"
        case .charging: "Charging"
        case .acPlugged: "Plugged In"
        }
    }

    /// SF Symbol name used to annotate the battery glyph or accessory.
    public var systemImage: String {
        switch self {
        case .onBattery: "battery.100percent"
        case .charging: "bolt.fill"
        case .acPlugged: "powerplug.fill"
        }
    }
}
