import Foundation
@testable import PeakmonCollectors
import PeakmonCore
import Testing

@Suite("SMC thermal sampling")
struct ThermalCollectorTests {
    private let now = Date(timeIntervalSince1970: 100)

    @Test func m5UsesMappedSensorsWithoutMixingOldKeys() async {
        let bridge = ThermalSamplingReader(values: [
            "Tp00": 55, "Tp04": 62, "Tg0d": 48, "Tg0X": 51,
            "Tp05": 120, "Tg0D": 130, "TC0P": 90, "TG0P": 95,
        ])
        let collector = ThermalCollector(cpuBrand: "Apple M5 Pro", bridge: bridge)
        let samples = await collector.collect(at: now)
        #expect(samples.first { $0.kind == .thermalCPU }?.value == 62)
        #expect(samples.first { $0.kind == .thermalGPU }?.value == 51)
        #expect(samples.allSatisfy { $0.isAvailable && $0.unit == .celsius && $0.timestamp == now })
        #expect(!bridge.readKeys.contains("Tp05"))
        #expect(!bridge.readKeys.contains("Tg0D"))
        #expect(!bridge.readKeys.contains("TC0P"))
        #expect(!bridge.readKeys.contains("TG0P"))
    }

    @Test func m3SeparatesCPUAndGPUWithinTheSamePrefix() async {
        let bridge = ThermalSamplingReader(values: ["Te05": 42, "Tf04": 68, "Tf14": 57])
        let collector = ThermalCollector(cpuBrand: "Apple M3 Max", bridge: bridge)
        let samples = await collector.collect(at: now)
        #expect(samples.first { $0.kind == .thermalCPU }?.value == 68)
        #expect(samples.first { $0.kind == .thermalGPU }?.value == 57)
    }

    @Test func invalidDieValuesFallBackPerCategory() async {
        let bridge = ThermalSamplingReader(values: [
            "Tp00": .nan, "Tp04": 0, "Tp08": 150, "Tp0C": -.infinity,
            "TC0P": 43.5, "Tg0U": 56, "TG0P": 120,
        ])
        let collector = ThermalCollector(cpuBrand: "Apple M5", bridge: bridge)
        let samples = await collector.collect(at: now)
        #expect(samples.first { $0.kind == .thermalCPU }?.value == 43.5)
        #expect(samples.first { $0.kind == .thermalGPU }?.value == 56)
        #expect(!bridge.readKeys.contains("TG0P"))
    }

    @Test func readErrorsDoNotBlockAWorkingProximitySensor() async {
        let bridge = ThermalSamplingReader(values: ["TC0P": 44, "TG0P": 40])
        bridge.setFailure(.unsupportedType(SMCKey("Tp00"), type: "new!"), for: "Tp00")
        let collector = ThermalCollector(cpuBrand: "Apple M5", bridge: bridge)
        let samples = await collector.collect(at: now)
        #expect(samples.first { $0.kind == .thermalCPU }?.value == 44)
        #expect(samples.first { $0.kind == .thermalGPU }?.value == 40)
    }

    @Test func initiallyMissingSensorsAreRetried() async {
        let bridge = ThermalSamplingReader(values: [:])
        let collector = ThermalCollector(cpuBrand: "Apple M5", bridge: bridge)
        let first = await collector.collect(at: now)
        #expect(first.allSatisfy { !$0.isAvailable })
        let firstReadCount = bridge.readKeys.count
        bridge.setValue(61, for: "Tp00")
        _ = await collector.collect(at: now.addingTimeInterval(1))
        #expect(bridge.readKeys.count == firstReadCount)
        let recovered = await collector.collect(at: now.addingTimeInterval(30))
        #expect(recovered.first { $0.kind == .thermalCPU }?.value == 61)
        #expect(recovered.first { $0.kind == .thermalCPU }?.isAvailable == true)
    }

    @Test func transientReadFailureRecoversOnNextTick() async {
        let bridge = ThermalSamplingReader(values: ["Tp00": 61])
        bridge.setFailure(.callFailed(-1, command: 5), for: "Tp00")
        let collector = ThermalCollector(cpuBrand: "Apple M5", bridge: bridge)
        _ = await collector.collect(at: now)
        bridge.setFailure(nil, for: "Tp00")
        let recovered = await collector.collect(at: now.addingTimeInterval(1))
        #expect(recovered.first { $0.kind == .thermalCPU }?.value == 61)
    }

    @Test func lostReadingsInvalidateThePreviouslyLiveTemperature() async {
        let bridge = ThermalSamplingReader(values: ["Tp00": 61, "Tg0U": 52])
        let collector = ThermalCollector(cpuBrand: "Apple M5", bridge: bridge)
        _ = await collector.collect(at: now)
        bridge.setValue(0, for: "Tp00")
        bridge.setValue(.infinity, for: "Tg0U")
        let unavailable = await collector.collect(at: now.addingTimeInterval(1))
        #expect(unavailable.count == 2)
        #expect(unavailable.allSatisfy { !$0.isAvailable })
    }

    @Test func absentBridgeProducesUnavailableSamples() async {
        let collector = ThermalCollector(cpuBrand: "Apple M5 Pro", bridge: nil)
        let samples = await collector.collect(at: now)
        #expect(Set(samples.map(\.kind)) == [.thermalCPU, .thermalGPU])
        #expect(samples.allSatisfy { !$0.isAvailable && $0.timestamp == now })
    }
}

private final class ThermalSamplingReader: SMCThermalReading, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Double]
    private var failures: [String: SMCError] = [:]
    private var reads: [String] = []

    init(values: [String: Double]) { self.values = values }

    var readKeys: [String] { lock.withLock { reads } }

    func setValue(_ value: Double, for key: String) {
        lock.withLock { values[key] = value }
    }

    func setFailure(_ error: SMCError?, for key: String) {
        lock.withLock { failures[key] = error }
    }

    func readDouble(_ key: SMCKey) throws -> Double {
        try lock.withLock {
            reads.append(key.fourCC)
            if let error = failures[key.fourCC] { throw error }
            guard let value = values[key.fourCC] else { throw SMCError.keyNotFound(key) }
            return value
        }
    }
}
