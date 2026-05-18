//
//  BatteryCollector.swift
//  PeakmonCollectors
//
//  Reports battery level (% of design capacity) plus the current
//  power-source state (on battery / charging / plugged in & full)
//  via IOKit's `IOPSCopyPowerSourcesInfo`. On desktops with no
//  battery this collector returns an empty array.
//

import Foundation
import IOKit.ps
import PeakmonCore

public final class BatteryCollector: MetricCollector {
    public let identifier = "battery.host"

    public init() {}

    public func collect() async throws -> [MetricSample] {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return []
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }

            let type = description[kIOPSTypeKey] as? String
            guard type == kIOPSInternalBatteryType else { continue }

            guard let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int,
                  max > 0 else { continue }

            let percent = Double(current) / Double(max) * 100.0
            let powerSource = Self.derivePowerSource(from: description)

            return [
                MetricSample(kind: .batteryLevel, unit: .percent, value: percent),
                MetricSample(
                    kind: .batteryPowerSource,
                    unit: .count,
                    value: powerSource.metricValue,
                ),
            ]
        }
        return []
    }

    private static func derivePowerSource(
        from description: [String: Any],
    ) -> BatteryPowerSource {
        let state = description[kIOPSPowerSourceStateKey] as? String
        let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false

        if state == kIOPSACPowerValue {
            return isCharging ? .charging : .acPlugged
        }
        return .onBattery
    }
}
