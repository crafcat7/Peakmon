import Foundation
@testable import PeakmonCollectors
import PeakmonCore
import Testing

@Suite("Power compatibility")
struct PowerCompatibilityTests {
    private let now = Date(timeIntervalSince1970: 100)

    private func reading(_ name: String, _ value: Int64, _ unit: String = "mJ") -> IOReportBridge.Reading {
        .init(group: "Energy Model", channel: name, unit: unit, value: value)
    }

    private func sample(_ kind: MetricKind, in samples: [MetricSample]) -> MetricSample? {
        samples.first { $0.kind == kind }
    }

    @Test func frozenLegacyRailsDoNotBecomeZeroWattsOrPartialPackage() {
        var resolver = PowerCollector.FrameResolver()
        let result = resolver.samples(readings: [
            reading("CPU Energy", 0), reading("GPU0", 0), reading("DRAM0", 0), reading("DISP0", 0),
            reading("GPU Energy", 987_654, "nJ"),
        ], elapsed: 1, timestamp: now)
        for kind in [MetricKind.powerCPU, .powerGPUCore, .powerDRAM, .powerDisplay, .powerPackage] {
            #expect(sample(kind, in: result)?.isAvailable == false)
        }
        #expect(sample(.powerGPU, in: result)?.isAvailable == true)
        #expect(abs((sample(.powerGPU, in: result)?.value ?? 0) - 0.000987654) < 1e-12)
    }

    @Test func liveProviderPreservesIdleZeroAndAvoidsSummaryDoubleCounting() {
        var resolver = PowerCollector.FrameResolver()
        let result = resolver.samples(readings: [
            reading("CPU Energy", 1_000), reading("EACC_CPU", 2_000), reading("EACC_CPU0", 2_000),
            reading("GPU0", 300), reading("GPU CS0", 200), reading("GPU SRAM0", 100),
            reading("GPU Energy", 999_000_000, "nJ"), reading("DRAM0", 0), reading("DISP0", 0),
        ], elapsed: 1, timestamp: now)
        #expect(sample(.powerCPU, in: result)?.value == 1)
        #expect(abs((sample(.powerGPU, in: result)?.value ?? 0) - 0.6) < 1e-12)
        #expect(sample(.powerDRAM, in: result)?.isAvailable == true)
        #expect(sample(.powerDRAM, in: result)?.value == 0)
        #expect(abs((sample(.powerPackage, in: result)?.value ?? 0) - 1.6) < 1e-12)
    }

    @Test func stalledProviderBecomesUnavailableThenRecovers() {
        var resolver = PowerCollector.FrameResolver()
        _ = resolver.samples(readings: [reading("CPU Energy", 100)], elapsed: 1, timestamp: now)
        for index in 1...3 {
            let result = resolver.samples(readings: [reading("CPU Energy", 0), reading("GPU Energy", 500_000_000, "nJ")], elapsed: 1, timestamp: now)
            #expect(sample(.powerCPU, in: result)?.isAvailable == (index < 3))
            #expect(sample(.powerGPU, in: result)?.value == 0.5)
        }
        let recovered = resolver.samples(readings: [reading("CPU Energy", 200)], elapsed: 1, timestamp: now)
        #expect(sample(.powerCPU, in: recovered)?.isAvailable == true)
        #expect(sample(.powerCPU, in: recovered)?.value == 0.2)
    }

    @Test func missingAndInvalidChannelsDoNotBecomeMeasuredZero() {
        var resolver = PowerCollector.FrameResolver()
        let result = resolver.samples(readings: [reading("CPU Energy", 100), reading("DRAM0", .min), reading("DISP0", -1)], elapsed: 1, timestamp: now)
        #expect(sample(.powerGPU, in: result)?.isAvailable == false)
        #expect(sample(.powerDRAM, in: result)?.isAvailable == false)
        #expect(sample(.powerDisplay, in: result)?.isAvailable == false)
        #expect(sample(.powerPackage, in: result)?.isAvailable == false)
        for elapsed in [0.0, -1, .nan, .infinity] {
            #expect(resolver.samples(readings: [reading("CPU Energy", 100)], elapsed: elapsed, timestamp: now).allSatisfy { !$0.isAvailable })
        }
    }

    @Test func diePrefixesAndEnergyUnitsAreNormalized() {
        var resolver = PowerCollector.FrameResolver()
        let result = resolver.samples(readings: [
            reading("DIE0 CPU Energy", 1000), reading("DIE1 CPU Energy", 1000),
            reading("DIE0 GPU0", 100), reading("DIE1 GPU1", 100), reading("DIE1 DRAM1", 100),
        ], elapsed: 2, timestamp: now)
        #expect(sample(.powerCPU, in: result)?.value == 1)
        #expect(sample(.powerGPU, in: result)?.value == 0.1)
        #expect(sample(.powerDRAM, in: result)?.value == 0.05)
        let modern = resolver.samples(readings: [reading("CPU Energy", 1_000_000, "uJ"), reading("GPU Energy", 500_000_000, "nJ")], elapsed: 2, timestamp: now)
        #expect(sample(.powerCPU, in: modern)?.value == 0.5)
        #expect(sample(.powerGPU, in: modern)?.value == 0.25)
    }

    @Test func invalidConstituentCannotProducePartialRailTotals() {
        var resolver = PowerCollector.FrameResolver()
        let result = resolver.samples(readings: [
            reading("CPU Energy", 1_000), reading("GPU0", .min), reading("GPU CS0", 100),
            reading("GPU Energy", 500_000_000, "nJ"), reading("DRAM0", 100), reading("DCS0", .min),
        ], elapsed: 1, timestamp: now)
        #expect(sample(.powerGPU, in: result)?.value == 0.5)
        #expect(sample(.powerGPUCore, in: result)?.isAvailable == false)
        #expect(sample(.powerDRAM, in: result)?.isAvailable == false)
        #expect(sample(.powerPackage, in: result)?.value == 1.5)
    }

    @Test func smcMappingIsRestrictedAndRequiresEveryValidRail() {
        #expect(PowerCollector.m3MaxCPUWatts(chip: "Apple M3 Max", values: [1, 2, 3, 4, 5]) == 15)
        #expect(PowerCollector.m3MaxCPUWatts(chip: "Apple M3 Max", values: [0, 0, 0, 0, 0]) == 0)
        for chip in ["Apple M3 Pro", "Apple M4 Max", "Apple M3 Max Extra", ""] {
            #expect(PowerCollector.m3MaxCPUWatts(chip: chip, values: [1, 2, 3, 4, 5]) == nil)
        }
        for invalid: Double? in [nil, -1, .nan, .infinity] {
            #expect(PowerCollector.m3MaxCPUWatts(chip: "Apple M3 Max", values: [1, 2, 3, 4, invalid]) == nil)
        }
        #expect(PowerCollector.m3MaxCPUWatts(chip: "Apple M3 Max", values: [1, 2]) == nil)
    }

    @Test func smcCPUReadingRetainsSupplyScopeAndRejectsInvalidInput() {
        let valid = PowerCollector.m3MaxCPUSupplySample(9, at: now)
        #expect(valid.kind == .powerCPUSupply)
        #expect(valid.unit == .watts)
        #expect(valid.value == 9)
        #expect(valid.timestamp == now)
        #expect(valid.isAvailable)

        for watts: Double? in [nil, -1, .nan, .infinity] {
            let sample = PowerCollector.m3MaxCPUSupplySample(watts, at: now)
            #expect(sample.kind == .powerCPUSupply)
            #expect(sample.timestamp == now)
            #expect(!sample.isAvailable)
        }
    }

    @Test func invalidSystemPowerBecomesUnavailableInsteadOfZeroOrStale() {
        let valid = SystemPowerCollector.makeSample(value: 7.5, timestamp: now)
        #expect(valid.isAvailable)
        #expect(valid.value == 7.5)
        for value: Double? in [nil, -1, .nan, .infinity] {
            let sample = SystemPowerCollector.makeSample(value: value, timestamp: now)
            #expect(!sample.isAvailable)
            #expect(sample.kind == .powerSystem)
            #expect(sample.timestamp == now)
        }
    }

    @Test func smcWindowAverageRequiresCompleteFiniteNonnegativeFrames() {
        let frames = [
            ["PSTR": 6.0, "PC02": 1.0, "PMVC": 4.0],
            ["PSTR": 10.0, "PC02": 3.0],
            ["PSTR": 8.0, "PC02": 2.0, "PMVC": 6.0],
        ]
        let averaged = PowerCollector.averageSMCFrames(
            frames,
            keys: ["PSTR", "PC02", "PMVC"],
        )
        #expect(averaged["PSTR"] == 8)
        #expect(averaged["PC02"] == 2)
        #expect(averaged["PMVC"] == nil)

        let invalid = PowerCollector.averageSMCFrames(
            [["PSTR": 6], ["PSTR": -.infinity]],
            keys: ["PSTR"],
        )
        #expect(invalid.isEmpty)
    }
}
