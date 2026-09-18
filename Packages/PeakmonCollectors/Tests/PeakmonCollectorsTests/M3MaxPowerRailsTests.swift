import Foundation
@testable import PeakmonCollectors
import PeakmonCore
import Testing

@Suite("M3 Max SMC power rails")
struct M3MaxPowerRailsTests {
    private static let timestamp = Date(timeIntervalSinceReferenceDate: 100)
    private static let readings: [String: Double] = [
        "PC10": 1,
        "PC12": 2,
        "PC20": 3,
        "PC22": 4,
        "PC40": 0.5,
        "PMVC": 4,
        "PDBR": 2.5,
    ]
    private static let kinds: Set<MetricKind> = [
        .powerGPUClusters, .powerGPUShared, .powerDRAMSupply, .powerDisplayBacklight,
    ]

    @Test func allKeysHaveStableUniqueReadOrder() {
        #expect(M3MaxPowerRails.allKeys == ["PC10", "PC12", "PC20", "PC22", "PC40", "PMVC", "PDBR"])
        #expect(Set(M3MaxPowerRails.allKeys).count == M3MaxPowerRails.allKeys.count)
    }

    @Test func validatedChipProducesFourIndependentSupplyReadings() {
        let samples = Self.samples(readings: Self.readings)
        let byKind = Dictionary(uniqueKeysWithValues: samples.map { ($0.kind, $0) })
        #expect(samples.count == 4)
        #expect(Set(byKind.keys) == Self.kinds)
        #expect(samples.allSatisfy { $0.isAvailable && $0.unit == .watts && $0.timestamp == Self.timestamp })
        #expect(byKind[.powerGPUClusters]?.value == 10)
        #expect(byKind[.powerGPUShared]?.value == 0.5)
        #expect(byKind[.powerDRAMSupply]?.value == 4)
        #expect(byKind[.powerDisplayBacklight]?.value == 2.5)
    }

    @Test(arguments: ["Apple M3", "Apple M3 Pro", "Apple M4 Max", "Apple M3 Max ", "apple m3 max", "", "Mac15,9"])
    func unvalidatedChipProducesOnlyUnavailableMarkers(chip: String) {
        let samples = M3MaxPowerRails.samples(chip: chip, readings: Self.readings, timestamp: Self.timestamp)
        #expect(samples.count == 4)
        #expect(Set(samples.map(\.kind)) == Self.kinds)
        #expect(samples.allSatisfy { !$0.isAvailable && $0.value.isFinite && $0.timestamp == Self.timestamp })
    }

    @Test func absentReadingsProduceFourUnavailableMarkers() {
        let samples = Self.samples(readings: [:])
        #expect(samples.count == 4)
        #expect(samples.allSatisfy { !$0.isAvailable && $0.value == 0 })
    }

    @Test func zeroIsAValidMeasuredValueForEveryRail() {
        let readings = Dictionary(uniqueKeysWithValues: M3MaxPowerRails.allKeys.map { ($0, 0.0) })
        let samples = Self.samples(readings: readings)
        #expect(samples.count == 4)
        #expect(samples.allSatisfy { $0.isAvailable && $0.value == 0 })
    }

    @Test(arguments: ["PC10", "PC12", "PC20", "PC22", "PC40", "PMVC", "PDBR"])
    func missingKeyInvalidatesOnlyItsOwnRail(key: String) {
        var readings = Self.readings
        readings[key] = nil
        let samples = Self.samples(readings: readings)
        let unavailable = samples.filter { !$0.isAvailable }
        #expect(unavailable.map(\.kind) == [Self.kind(for: key)])
        #expect(samples.filter(\.isAvailable).count == 3)
    }

    @Test(arguments: ["PC10", "PC12", "PC20", "PC22", "PC40", "PMVC", "PDBR"])
    func invalidKeyValuesInvalidateOnlyTheirOwnRail(key: String) {
        for invalidValue in [-1.0, Double.nan, Double.infinity, -Double.infinity] {
            var readings = Self.readings
            readings[key] = invalidValue
            let samples = Self.samples(readings: readings)
            #expect(samples.filter { !$0.isAvailable }.map(\.kind) == [Self.kind(for: key)])
            #expect(samples.filter(\.isAvailable).count == 3)
            #expect(samples.allSatisfy { $0.value.isFinite })
        }
    }

    @Test func overflowingGPUClusterTotalIsUnavailable() {
        var readings = Self.readings
        for key in M3MaxPowerRails.gpuClusterKeys {
            readings[key] = Double.greatestFiniteMagnitude
        }
        let samples = Self.samples(readings: readings)
        #expect(samples.filter { !$0.isAvailable }.map(\.kind) == [.powerGPUClusters])
        #expect(samples.filter(\.isAvailable).count == 3)
    }

    @Test func supplyReadingsNeverPublishEnergyModelOrPackageKinds() {
        let energyKinds: Set<MetricKind> = [
            .powerCPU, .powerCPUSupply, .powerGPU, .powerGPUCore, .powerGPUCommandStreamer,
            .powerGPUSRAM, .powerDRAM, .powerDisplay, .powerPackage, .powerSystem,
        ]
        var readings = Self.readings
        readings["PSTR"] = 99
        readings["PHPC"] = 88
        let samples = Self.samples(readings: readings)
        #expect(energyKinds.isDisjoint(with: samples.map(\.kind)))
        #expect(samples.first { $0.kind == .powerGPUClusters }?.value == 10)
    }

    private static func samples(readings: [String: Double]) -> [MetricSample] {
        M3MaxPowerRails.samples(chip: "Apple M3 Max", readings: readings, timestamp: timestamp)
    }

    private static func kind(for key: String) -> MetricKind {
        switch key {
        case "PC40": .powerGPUShared
        case "PMVC": .powerDRAMSupply
        case "PDBR": .powerDisplayBacklight
        default: .powerGPUClusters
        }
    }
}
