//
//  BatteryCollector.swift
//  PeakmonCollectors
//
//  Reports battery level (% of current full capacity), power-source state,
//  and — when an AppleSmartBattery IOService is present — cycle count,
//  health (nominal or full charge capacity / design capacity, in %), battery
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

            let samples = Self.powerSourceSamples(from: description)
            if !samples.isEmpty { return samples }
        }
        return []
    }

    static func powerSourceSamples(from description: [String: Any]) -> [MetricSample] {
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              description[kIOPSIsPresentKey] as? Bool != false,
              let current = integerValue(for: kIOPSCurrentCapacityKey, in: description),
              let maximum = integerValue(for: kIOPSMaxCapacityKey, in: description),
              maximum > 0, current >= 0, current <= maximum else { return [] }

        let percent = Double(current) / Double(maximum) * 100.0
        return [
            MetricSample(kind: .batteryLevel, unit: .percent, value: percent),
            MetricSample(
                kind: .batteryPowerSource,
                unit: .count,
                value: derivePowerSource(from: description).metricValue,
            ),
        ]
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

        if let health = Self.batteryHealth(from: dict) {
            out.append(MetricSample(
                kind: .batteryHealth,
                unit: .percent,
                value: health,
            ))
        }

        var smcTemperatures: [String: Double] = [:]
        if let smc = SMCBridge.shared {
            for key in ["TB1T", "TB2T", "TB0T"] {
                smcTemperatures[key] = try? smc.readDouble(SMCKey(key))
            }
        }
        if let celsius = Self.batteryCelsius(
            smcTemperatures: smcTemperatures,
            rawTemperature: Self.integerValue(for: "Temperature", in: dict),
        ) {
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

    static func batteryHealth(from properties: [String: Any]) -> Double? {
        let batteryData = properties["BatteryData"] as? [String: Any] ?? [:]
        func positiveCapacity(_ key: String) -> Int? {
            for dictionary in [properties, batteryData] {
                if let value = integerValue(for: key, in: dictionary), value > 0 {
                    return value
                }
            }
            return nil
        }

        // Newer macOS versions expose these mAh fields in BatteryData.
        // Keep nominal capacity preferred, but this estimate can differ
        // from the system's separately calibrated maximum-capacity value.
        // MaxCapacity is deliberately excluded: it can be a percentage.
        guard let design = positiveCapacity("DesignCapacity"),
              let capacity = positiveCapacity("NominalChargeCapacity")
                  ?? positiveCapacity("AppleRawMaxCapacity")
                  ?? positiveCapacity("FullChargeCapacity") else { return nil }
        let health = Double(capacity) / Double(design) * 100.0
        guard health.isFinite, health > 0 else { return nil }
        return min(health, 100.0)
    }

    static func batteryCelsius(
        smcTemperatures: [String: Double],
        rawTemperature: Int?,
    ) -> Double? {
        func validSMCTemperature(_ key: String) -> Double? {
            guard let value = smcTemperatures[key], value.isFinite,
                  value > 0, value < 100 else { return nil }
            return value
        }

        // SMC thermistors already report Celsius. Zero is commonly an
        // unsupported sensor, so only average valid pack thermistors.
        let thermistors = ["TB1T", "TB2T"].compactMap(validSMCTemperature)
        if !thermistors.isEmpty {
            return thermistors.reduce(0, +) / Double(thermistors.count)
        }
        if let temperature = validSMCTemperature("TB0T") { return temperature }
        return rawTemperature.flatMap(smartBatteryCelsius)
    }

    static func smartBatteryCelsius(from rawValue: Int) -> Double? {
        guard rawValue > 0 else { return nil }

        let celsius = Double(rawValue) / 10.0 - 273.15
        guard (-20 ... 100).contains(celsius) else { return nil }
        return celsius
    }

    private static func integerValue(for key: String, in dict: [String: Any]) -> Int? {
        guard let number = dict[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return Int(exactly: number.doubleValue)
    }
}
