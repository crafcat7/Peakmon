//
//  BatteryCollector.swift
//  PeakmonCollectors
//
//  Reports battery level (% of design capacity), power-source state,
//  and — when an AppleSmartBattery IOService is present — cycle count,
//  health (AppleRawMaxCapacity / DesignCapacity, in %), battery
//  temperature (°C), and estimated time remaining (seconds,
//  charge-direction implicit by power source).
//
//  Level / source come from `IOPSCopyPowerSourcesInfo`, which is also
//  the source of truth for desktops + external batteries. The extra
//  metrics come from `AppleSmartBattery` via IORegistry. They
//  are emitted only when the keys are present and sensible.
//

import Foundation
import IOKit
import IOKit.ps
import PeakmonCore

public final class BatteryCollector: MetricCollector {
    public let identifier = "battery.host"

    public init() {}

    public func collect() async throws -> [MetricSample] {
        var samples = collectFromPowerSources()
        guard !samples.isEmpty else { return [] }
        samples.append(contentsOf: collectFromSmartBattery())
        return samples
    }

    // MARK: - IOPS (level + source)

    private func collectFromPowerSources() -> [MetricSample] {
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

    // MARK: - AppleSmartBattery (health + cycles + temperature + time)

    private func collectFromSmartBattery() -> [MetricSample] {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery"),
        )
        guard service != 0 else { return [] }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
            == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any]
        else { return [] }

        var out: [MetricSample] = []

        if let cycles = dict["CycleCount"] as? Int, cycles >= 0 {
            out.append(MetricSample(
                kind: .batteryCycleCount,
                unit: .count,
                value: Double(cycles),
            ))
        }

        // Health: matches macOS Settings → Battery (within rounding).
        // System Settings uses NominalChargeCapacity / DesignCapacity,
        // a smoothed/calibrated estimate that includes Apple's
        // age/temperature compensation. AppleRawMaxCapacity is the
        // unfiltered cell-side number (coconutBattery / Stats use
        // that one); it typically reads a few percent lower. We
        // intentionally pick the system value so the dashboard
        // agrees with the user-visible Settings panel.
        if let nominal = dict["NominalChargeCapacity"] as? Int,
           let design = dict["DesignCapacity"] as? Int,
           design > 0, nominal > 0 {
            let health = min(Double(nominal) / Double(design) * 100.0, 100.0)
            out.append(MetricSample(
                kind: .batteryHealth,
                unit: .percent,
                value: health,
            ))
        } else if let raw = dict["AppleRawMaxCapacity"] as? Int,
                  let design = dict["DesignCapacity"] as? Int,
                  design > 0 {
            // Fallback for hosts where NominalChargeCapacity is
            // absent (older T2 / Intel chassis). Slightly under-
            // reports vs. System Settings but is still a usable
            // wear indicator.
            let health = min(Double(raw) / Double(design) * 100.0, 100.0)
            out.append(MetricSample(
                kind: .batteryHealth,
                unit: .percent,
                value: health,
            ))
        }

        if let rawTemperature = Self.integerValue(for: "Temperature", in: dict),
           let celsius = Self.smartBatteryCelsius(from: rawTemperature) {
            out.append(MetricSample(
                kind: .batteryTemperature,
                unit: .celsius,
                value: celsius,
            ))
        }

        // TimeRemaining is reported in minutes by AppleSmartBattery.
        // 0xFFFF (65535) means "still computing" — skip in that case.
        // While charging, TimeToFullCharge takes over; pick whichever
        // is sensible based on IsCharging.
        let isCharging = (dict["IsCharging"] as? Bool) ?? false
        let candidate: Int? = isCharging
            ? dict["TimeToFullCharge"] as? Int
            : dict["TimeRemaining"] as? Int
        if let minutes = candidate, minutes > 0, minutes < 0xFFFF {
            out.append(MetricSample(
                kind: .batteryTimeRemaining,
                unit: .count,
                value: Double(minutes) * 60.0,
            ))
        }

        return out
    }

    static func smartBatteryCelsius(from rawValue: Int) -> Double? {
        guard rawValue > 0 else { return nil }

        let celsius = Double(rawValue) / 10.0 - 273.15
        guard (-20 ... 100).contains(celsius) else { return nil }
        return celsius
    }

    private static func integerValue(for key: String, in dict: [String: Any]) -> Int? {
        if let value = dict[key] as? Int { return value }
        if let value = dict[key] as? NSNumber { return value.intValue }
        return nil
    }
}
