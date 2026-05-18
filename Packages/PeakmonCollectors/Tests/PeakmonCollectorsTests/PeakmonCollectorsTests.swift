import Foundation
@testable import PeakmonCollectors
import PeakmonCore
import Testing

@Suite("PeakmonCollectors scaffolding")
struct PeakmonCollectorsTests {
    @Test func versionMarkerIsSet() {
        #expect(PeakmonCollectors.versionMarker == "v0.0-scaffold")
    }
}

@Suite("CPUCollector")
struct CPUCollectorTests {
    @Test func firstCallReturnsEmptyBaselineThenProducesSamples() async throws {
        let collector = CPUCollector()
        #expect(collector.identifier == "cpu.host")

        // First call only seeds the baseline; expect no samples yet.
        let first = try await collector.collect()
        #expect(first.isEmpty)

        // Burn a little CPU so the diff is non-zero, then sample again.
        try await Task.sleep(for: .milliseconds(50))
        var acc: Double = 1
        for index in 1 ..< 50_000 {
            acc += Double(index).squareRoot()
        }
        _ = acc

        let second = try await collector.collect()
        let kinds = Set(second.map(\.kind))
        #expect(kinds == [.cpuTotal, .cpuUser, .cpuSystem])
        for sample in second {
            #expect(sample.unit == .percent)
            #expect(sample.value >= 0)
            #expect(sample.value <= 100.5) // allow small fp slack
        }
        let total = second.first(where: { $0.kind == .cpuTotal })?.value
        let user = second.first(where: { $0.kind == .cpuUser })?.value
        let sys = second.first(where: { $0.kind == .cpuSystem })?.value
        if let total, let user, let sys {
            #expect(abs(total - (user + sys)) < 0.001)
        }
    }
}

@Suite("MemoryCollector")
struct MemoryCollectorTests {
    @Test func emitsUsedAndPressureSamples() async throws {
        let collector = MemoryCollector()
        #expect(collector.identifier == "memory.host")

        let samples = try await collector.collect()
        let kinds = Set(samples.map(\.kind))
        #expect(kinds == [.memoryUsed, .memoryPressure])

        let used = samples.first(where: { $0.kind == .memoryUsed })
        #expect(used?.unit == .bytes)
        #expect((used?.value ?? 0) > 0)

        let pressure = samples.first(where: { $0.kind == .memoryPressure })
        #expect(pressure?.unit == .percent)
        if let value = pressure?.value {
            #expect(value > 0)
            #expect(value <= 100)
        }
    }
}

@Suite("BatteryCollector")
struct BatteryCollectorTests {
    @Test func emitsLevelAndPowerSourceSamplesAndNeverThrows() async throws {
        let collector = BatteryCollector()
        #expect(collector.identifier == "battery.host")

        // Desktop Macs have no battery → empty array is a valid outcome.
        // Laptops should emit exactly 2 samples: level + powerSource.
        let samples = try await collector.collect()
        #expect(samples.isEmpty || samples.count == 2)

        if let level = samples.first(where: { $0.kind == .batteryLevel }) {
            #expect(level.unit == .percent)
            #expect(level.value >= 0)
            #expect(level.value <= 100)
        }

        if let powerSource = samples.first(where: { $0.kind == .batteryPowerSource }) {
            #expect(powerSource.unit == .count)
            let decoded = BatteryPowerSource(metricValue: powerSource.value)
            #expect(BatteryPowerSource.allCases.contains(decoded))
        }
    }
}

@Suite("DiskCollector")
struct DiskCollectorTests {
    @Test func emitsUsageImmediatelyAndRatesAfterSecondSample() async throws {
        let collector = DiskCollector()
        #expect(collector.identifier == "disk.host")

        let first = try await collector.collect()
        let firstKinds = Set(first.map(\.kind))
        // Usage samples are available on the first call; rates are not.
        #expect(firstKinds.contains(.diskUsed))
        #expect(firstKinds.contains(.diskTotal))
        #expect(!firstKinds.contains(.diskReadRate))

        try await Task.sleep(for: .milliseconds(50))
        let second = try await collector.collect()
        let secondKinds = Set(second.map(\.kind))
        #expect(secondKinds.contains(.diskReadRate))
        #expect(secondKinds.contains(.diskWriteRate))
        for sample in second where sample.kind == .diskReadRate || sample.kind == .diskWriteRate {
            #expect(sample.unit == .bytesPerSecond)
            #expect(sample.value >= 0)
        }
    }
}

@Suite("NetworkCollector")
struct NetworkCollectorTests {
    @Test func emitsRatesAfterSecondSample() async throws {
        let collector = NetworkCollector()
        #expect(collector.identifier == "net.host")

        // First call only seeds baseline.
        let first = try await collector.collect()
        #expect(first.isEmpty)

        try await Task.sleep(for: .milliseconds(50))
        let second = try await collector.collect()
        let kinds = Set(second.map(\.kind))
        #expect(kinds == [.netInRate, .netOutRate])
        for sample in second {
            #expect(sample.unit == .bytesPerSecond)
            #expect(sample.value >= 0)
        }
    }
}
