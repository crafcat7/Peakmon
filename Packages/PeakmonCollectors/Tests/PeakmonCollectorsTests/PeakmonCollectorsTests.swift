import Foundation
@testable import PeakmonCollectors
import PeakmonCore
import Testing

@Suite("ProcessCollector")
struct ProcessCollectorTests {
    @Test func exposesIdentifierAndOptionalLimit() {
        let collector = ProcessCollector()
        #expect(collector.identifier == "process.libproc")
        #expect(collector.limit == nil)

        let limited = ProcessCollector(limit: 10)
        #expect(limited.limit == 10)
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

    @Test func resetDropsBaseline() async throws {
        let collector = CPUCollector()
        _ = try await collector.collect()
        try await Task.sleep(for: .milliseconds(20))
        _ = try await collector.collect()

        await collector.reset()

        let afterReset = try await collector.collect()
        #expect(afterReset.isEmpty)
    }
}

@Suite("MemoryCollector")
struct MemoryCollectorTests {
    @Test func emitsUsedAndPressureSamples() async throws {
        let collector = MemoryCollector()
        #expect(collector.identifier == "memory.host")

        let samples = try await collector.collect()
        let kinds = Set(samples.map(\.kind))
        #expect(kinds.isSuperset(of: [.memoryUsed, .memoryPressure]))

        let used = samples.first(where: { $0.kind == .memoryUsed })
        #expect(used?.unit == .bytes)
        #expect((used?.value ?? 0) > 0)

        if let wired = samples.first(where: { $0.kind == .memoryWired }) {
            #expect(wired.unit == .bytes)
            #expect(wired.value >= 0)
        }

        if let compressed = samples.first(where: { $0.kind == .memoryCompressed }) {
            #expect(compressed.unit == .bytes)
            #expect(compressed.value >= 0)
        }

        if let swap = samples.first(where: { $0.kind == .memorySwapUsed }) {
            #expect(swap.unit == .bytes)
            #expect(swap.value >= 0)
        }

        if let pressureLevel = samples.first(where: { $0.kind == .memoryPressureLevel }) {
            #expect(pressureLevel.unit == .count)
            #expect([1, 2, 4, 8].contains(Int(pressureLevel.value)))
        }

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
    @Test func convertsSmartBatteryTemperatureFromTenthsKelvin() {
        let celsius = BatteryCollector.smartBatteryCelsius(from: 3066)
        #expect(celsius != nil)
        #expect(abs((celsius ?? 0) - 33.45) < 0.01)
        #expect(BatteryCollector.smartBatteryCelsius(from: 0) == nil)
        #expect(BatteryCollector.smartBatteryCelsius(from: 9999) == nil)
    }

    @Test func emitsLevelAndPowerSourceSamplesAndNeverThrows() async throws {
        let collector = BatteryCollector()
        #expect(collector.identifier == "battery.host")

        // Desktop Macs have no battery -> empty array is a valid outcome.
        // Laptops emit level + powerSource and may include SmartBattery
        // health/cycle/time metrics when IORegistry exposes them.
        let samples = try await collector.collect()
        let kinds = Set(samples.map(\.kind))
        #expect(samples.isEmpty || kinds.isSuperset(of: [.batteryLevel, .batteryPowerSource]))

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

        if let cycleCount = samples.first(where: { $0.kind == .batteryCycleCount }) {
            #expect(cycleCount.unit == .count)
            #expect(cycleCount.value >= 0)
        }

        if let health = samples.first(where: { $0.kind == .batteryHealth }) {
            #expect(health.unit == .percent)
            #expect(health.value > 0)
            #expect(health.value <= 100)
        }

        if let temperature = samples.first(where: { $0.kind == .batteryTemperature }) {
            #expect(temperature.unit == .celsius)
            #expect(temperature.value > -20)
            #expect(temperature.value < 100)
        }

        if let remaining = samples.first(where: { $0.kind == .batteryTimeRemaining }) {
            #expect(remaining.unit == .count)
            #expect(remaining.value > 0)
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

    @Test func resetDropsThroughputBaselineButKeepsUsageSamples() async throws {
        let collector = DiskCollector()
        _ = try await collector.collect()
        try await Task.sleep(for: .milliseconds(20))
        _ = try await collector.collect()

        await collector.reset()

        let afterReset = try await collector.collect()
        let kinds = Set(afterReset.map(\.kind))
        #expect(kinds.contains(.diskUsed))
        #expect(kinds.contains(.diskTotal))
        #expect(!kinds.contains(.diskReadRate))
        #expect(!kinds.contains(.diskWriteRate))
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

    @Test func resetDropsThroughputBaseline() async throws {
        let collector = NetworkCollector()
        _ = try await collector.collect()
        try await Task.sleep(for: .milliseconds(20))
        _ = try await collector.collect()

        await collector.reset()

        let afterReset = try await collector.collect()
        #expect(afterReset.isEmpty)
    }
}
