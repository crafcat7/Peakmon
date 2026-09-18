import Foundation
import IOKit.ps
@testable import PeakmonCollectors
import PeakmonCore
import Testing

@Suite("Battery compatibility")
struct BatteryCompatibilityTests {
    @Test func preservesTopLevelNominalAndRawCapacitySupport() {
        #expect(BatteryCollector.batteryHealth(from: [
            "NominalChargeCapacity": 8_000,
            "AppleRawMaxCapacity": 7_500,
            "DesignCapacity": 10_000,
        ]) == 80)
        #expect(BatteryCollector.batteryHealth(from: [
            "AppleRawMaxCapacity": 7_500,
            "DesignCapacity": 10_000,
        ]) == 75)
    }

    @Test func readsNestedCapacityAndKeepsNominalPreferred() {
        let health = BatteryCollector.batteryHealth(from: [
            "AppleRawMaxCapacity": 8_000,
            "MaxCapacity": 100,
            "BatteryData": [
                "NominalChargeCapacity": 8_251,
                "DesignCapacity": 8_579,
                "FullChargeCapacity": 8_007,
                "MaxCapacity": 100,
            ],
        ])
        #expect(abs((health ?? 0) - 96.1767105723) < 0.0001)
    }

    @Test func skipsInvalidTopLevelFieldsAndUsesNestedValues() {
        #expect(BatteryCollector.batteryHealth(from: [
            "NominalChargeCapacity": 0,
            "DesignCapacity": -1,
            "BatteryData": [
                "NominalChargeCapacity": NSNumber(value: 8_000),
                "DesignCapacity": NSNumber(value: 10_000),
            ],
        ]) == 80)
    }

    @Test func usesFullChargeCapacityOnlyAfterNominalAndRaw() {
        #expect(BatteryCollector.batteryHealth(from: [
            "NominalChargeCapacity": -1,
            "AppleRawMaxCapacity": 7_500,
            "BatteryData": ["DesignCapacity": 10_000, "FullChargeCapacity": 7_000],
        ]) == 75)
        #expect(BatteryCollector.batteryHealth(from: [
            "BatteryData": ["DesignCapacity": 10_000, "FullChargeCapacity": 7_000],
        ]) == 70)
    }

    @Test func neverTreatsPercentageMaxCapacityAsMilliampHours() {
        #expect(BatteryCollector.batteryHealth(from: [
            "DesignCapacity": 8_579,
            "MaxCapacity": 100,
            "CurrentCapacity": 83,
            "BatteryData": ["MaxCapacity": 100, "CurrentCapacity": 83],
        ]) == nil)
    }

    @Test func rejectsMissingAndMalformedCapacities() {
        #expect(BatteryCollector.batteryHealth(from: [:]) == nil)
        #expect(BatteryCollector.batteryHealth(from: ["NominalChargeCapacity": 8_000]) == nil)
        for invalid: Any in [0, -1, true, "8000", Double.nan, Double.infinity, 8_000.5] {
            #expect(BatteryCollector.batteryHealth(from: [
                "NominalChargeCapacity": invalid,
                "DesignCapacity": 10_000,
            ]) == nil)
            #expect(BatteryCollector.batteryHealth(from: [
                "NominalChargeCapacity": 8_000,
                "DesignCapacity": invalid,
            ]) == nil)
        }
        #expect(BatteryCollector.batteryHealth(from: [
            "NominalChargeCapacity": 10_200,
            "DesignCapacity": 10_000,
        ]) == 100)
    }

    @Test func averagesSMCThermistorsDirectlyInCelsius() {
        let temperature = BatteryCollector.batteryCelsius(
            smcTemperatures: ["TB1T": 29.9, "TB2T": 30.2, "TB0T": 30.2],
            rawTemperature: 3_066,
        )
        #expect(abs((temperature ?? 0) - 30.05) < 0.0001)
    }

    @Test func usesOnlyValidThermistorsBeforeAggregateSensor() {
        #expect(BatteryCollector.batteryCelsius(
            smcTemperatures: ["TB1T": .nan, "TB2T": 30.2, "TB0T": 32],
            rawTemperature: nil,
        ) == 30.2)
        for invalid in [Double.nan, .infinity, -.infinity, 0, -21, 100, 3_066] {
            #expect(BatteryCollector.batteryCelsius(
                smcTemperatures: ["TB1T": invalid, "TB2T": invalid, "TB0T": 30.2],
                rawTemperature: nil,
            ) == 30.2)
        }
    }

    @Test func preservesLegacyIORegistryTemperatureAsFinalFallback() {
        let temperature = BatteryCollector.batteryCelsius(
            smcTemperatures: ["TB1T": .nan, "TB2T": 0, "TB0T": .infinity],
            rawTemperature: 3_066,
        )
        #expect(abs((temperature ?? 0) - 33.45) < 0.0001)
        #expect(BatteryCollector.batteryCelsius(smcTemperatures: [:], rawTemperature: nil) == nil)
        #expect(BatteryCollector.batteryCelsius(smcTemperatures: [:], rawTemperature: 0) == nil)
    }

    @Test func requiresPresentInternalBatteryBeforeSupplementaryCollection() {
        // collect() only reads AppleSmartBattery/SMC after this gate emits
        // samples, so desktops and external UPS sources cannot emit them.
        #expect(BatteryCollector.powerSourceSamples(from: [:]).isEmpty)
        #expect(BatteryCollector.powerSourceSamples(from: [
            kIOPSTypeKey: "UPS",
            kIOPSCurrentCapacityKey: 83,
            kIOPSMaxCapacityKey: 100,
        ]).isEmpty)
        #expect(BatteryCollector.powerSourceSamples(from: [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSIsPresentKey: false,
            kIOPSCurrentCapacityKey: 83,
            kIOPSMaxCapacityKey: 100,
        ]).isEmpty)

        let samples = BatteryCollector.powerSourceSamples(from: [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSCurrentCapacityKey: 83,
            kIOPSMaxCapacityKey: 100,
            kIOPSPowerSourceStateKey: kIOPSACPowerValue,
        ])
        #expect(samples.first(where: { $0.kind == .batteryLevel })?.value == 83)
        #expect(samples.first(where: { $0.kind == .batteryPowerSource })?.value
            == BatteryPowerSource.acPlugged.metricValue)
    }

    @Test func rejectsInvalidLevelBeforeSupplementaryCollection() {
        for invalid: Any in [-1, 101, true, Double.nan, Double.infinity] {
            #expect(BatteryCollector.powerSourceSamples(from: [
                kIOPSTypeKey: kIOPSInternalBatteryType,
                kIOPSCurrentCapacityKey: invalid,
                kIOPSMaxCapacityKey: 100,
            ]).isEmpty)
        }
    }
}
