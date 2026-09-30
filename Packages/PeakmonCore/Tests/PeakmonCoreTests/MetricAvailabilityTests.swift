import Foundation
@testable import PeakmonCore
import Testing

@Suite("Metric availability")
struct MetricAvailabilityTests {
    @Test func legacyJSONDefaultsToAvailable() throws {
        let json = Data("""
        {
            "id": "D6201E85-C0C3-4533-BFA7-3292E7BEA209",
            "kind": "power.cpu",
            "unit": "watts",
            "value": 0,
            "timestamp": 0
        }
        """.utf8)
        let sample = try JSONDecoder().decode(MetricSample.self, from: json)
        #expect(sample.isAvailable)
        #expect(sample.value == 0)
        #expect(sample.timestamp == Date(timeIntervalSinceReferenceDate: 0))

        let encoded = try JSONEncoder().encode(sample)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == ["id", "kind", "unit", "value", "timestamp"])
    }

    @Test func availabilitySurvivesJSONRoundTrip() throws {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let samples = [
            MetricSample(kind: .powerCPU, unit: .watts, value: 0, timestamp: now),
            MetricSample.unavailable(kind: .powerCPU, unit: .watts, timestamp: now),
        ]
        let encoded = try JSONEncoder().encode(samples)
        let decoded = try JSONDecoder().decode([MetricSample].self, from: encoded)
        #expect(decoded == samples)
        #expect(decoded.map(\.isAvailable) == [true, false])
    }

    @Test func unavailableMarkerHasFinitePlaceholder() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let sample = MetricSample.unavailable(kind: .powerDRAM, unit: .watts, timestamp: now)
        #expect(!sample.isAvailable)
        #expect(sample.value.isFinite)
        #expect(sample.value == 0)
        #expect(sample.kind == .powerDRAM)
        #expect(sample.unit == .watts)
        #expect(sample.timestamp == now)
    }

    @Test @MainActor func unavailableReadingPreservesHistoryAndRecovers() {
        let store = MetricsStore(historyLimit: 2)
        let first = MetricSample(kind: .powerCPU, unit: .watts, value: 8)
        let other = MetricSample(kind: .powerSystem, unit: .watts, value: 20)
        store.ingest([first, other])
        store.ingest([.unavailable(kind: .powerCPU, unit: .watts)])

        #expect(store.latest(for: .powerCPU) == nil)
        #expect(store.value(for: .powerCPU) == 0)
        #expect(store.value(for: .powerCPU, default: -1) == -1)
        #expect(store.history(for: .powerCPU) == [first])
        #expect(store.historySuffix(for: .powerCPU, limit: 1) == [first])
        #expect(store.hasHistory(for: .powerCPU))
        #expect(store.latest(for: .powerSystem) == other)

        let recovered = MetricSample(kind: .powerCPU, unit: .watts, value: 0)
        store.ingest([recovered])
        #expect(store.latest(for: .powerCPU) == recovered)
        #expect(store.value(for: .powerCPU, default: -1) == 0)
        #expect(store.history(for: .powerCPU) == [first, recovered])
    }

    @Test @MainActor func unavailableFirstReadingCreatesNoHistory() {
        let store = MetricsStore()
        store.ingest([.unavailable(kind: .powerCPU, unit: .watts)])
        #expect(store.latest(for: .powerCPU) == nil)
        #expect(store.value(for: .powerCPU, default: -1) == -1)
        #expect(!store.hasHistory(for: .powerCPU))
        #expect(store.history(for: .powerCPU).isEmpty)
    }

    @Test @MainActor func liveLookupRejectsStaleSamplesWithoutDroppingHistory() {
        let store = MetricsStore()
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let sample = MetricSample(
            kind: .powerSystem,
            unit: .watts,
            value: 12,
            timestamp: now.addingTimeInterval(-9),
        )
        store.ingest([sample])

        #expect(store.latest(for: .powerSystem, maximumAge: 8, at: now) == nil)
        #expect(store.latest(for: .powerSystem, maximumAge: 9, at: now) == sample)
        #expect(store.latest(for: .powerSystem) == sample)
        #expect(store.history(for: .powerSystem) == [sample])
        #expect(store.latest(for: .powerSystem, maximumAge: -.infinity, at: now) == nil)
    }

    @Test @MainActor func resetClearsHistoryAndAvailabilityState() {
        let store = MetricsStore()
        store.ingest([
            MetricSample(kind: .powerCPU, unit: .watts, value: 8),
            .unavailable(kind: .powerCPU, unit: .watts),
        ])
        store.reset()
        #expect(store.latest(for: .powerCPU) == nil)
        #expect(!store.hasHistory(for: .powerCPU))
        #expect(store.history(for: .powerCPU).isEmpty)

        let sample = MetricSample(kind: .powerCPU, unit: .watts, value: 5)
        store.ingest([sample])
        #expect(store.latest(for: .powerCPU) == sample)
        #expect(store.history(for: .powerCPU) == [sample])
    }

    @Test func recorderPreparationExcludesMarkersAndKeepsMeasuredZero() {
        let zero = MetricSample(kind: .powerCPU, unit: .watts, value: 0)
        let marker = MetricSample.unavailable(kind: .powerCPU, unit: .watts)
        #expect(HistoryRecorder.shouldRecord(zero))
        #expect(!HistoryRecorder.shouldRecord(marker))
        #expect(HistoryRecorder.prepareSamples([marker, zero]) == [zero])
    }

    @Test func recorderPreparedEntryExcludesUnavailableValues() async {
        let recorder = HistoryRecorder()
        let now = Date(timeIntervalSince1970: 200_000)
        await recorder.ingestPrepared([
            MetricSample(kind: .powerCPU, unit: .watts, value: 8, timestamp: now),
            .unavailable(kind: .powerCPU, unit: .watts, timestamp: now.addingTimeInterval(0.2)),
            MetricSample(kind: .powerCPU, unit: .watts, value: 0, timestamp: now.addingTimeInterval(0.4)),
        ])

        let buckets = await recorder.buckets(for: .powerCPU, range: .oneHour, now: now.addingTimeInterval(1))
        #expect(buckets.count == 1)
        #expect(buckets.first?.count == 2)
        #expect(buckets.first?.avg == 4)
        #expect(buckets.first?.last == 0)
    }

    @Test func recorderPreparedEntryDoesNotFeedUnavailableValuesToAnomalies() async {
        let recorder = HistoryRecorder()
        let now = Date(timeIntervalSince1970: 200_000)
        await recorder.ingestPrepared([
            MetricSample(kind: .cpuTotal, unit: .percent, value: 99, timestamp: now, isAvailable: false),
            MetricSample(kind: .cpuTotal, unit: .percent, value: 99, timestamp: now.addingTimeInterval(6), isAvailable: false),
        ])
        let buckets = await recorder.buckets(for: .cpuTotal, range: .oneHour, now: now.addingTimeInterval(7))
        let anomalies = await recorder.anomalies(in: .oneHour, at: now.addingTimeInterval(7))
        #expect(buckets.isEmpty)
        #expect(anomalies.isEmpty)
    }

    @Test func historyStoreDirectEntryExcludesMarkersAndKeepsMeasuredZero() async {
        let store = HistoryStore()
        let now = Date(timeIntervalSince1970: 200_000)
        await store.ingest([
            MetricSample(kind: .powerCPU, unit: .watts, value: 8, timestamp: now),
            .unavailable(kind: .powerCPU, unit: .watts, timestamp: now.addingTimeInterval(0.2)),
            MetricSample(kind: .powerCPU, unit: .watts, value: 0, timestamp: now.addingTimeInterval(0.4)),
        ])

        let buckets = await store.buckets(for: .powerCPU, range: .oneHour, now: now.addingTimeInterval(1))
        #expect(buckets.count == 1)
        #expect(buckets.first?.count == 2)
        #expect(buckets.first?.avg == 4)
        #expect(buckets.first?.min == 0)
        #expect(buckets.first?.max == 8)
        #expect(buckets.first?.last == 0)
    }

    @Test func smcSupplyKindsHaveDistinctStableSerializedNames() throws {
        let expected: [(MetricKind, String)] = [
            (.powerCPUSupply, "power.cpu.supply"),
            (.powerDRAMSupply, "power.dram.supply"),
            (.powerDisplayBacklight, "power.display.backlight"),
            (.powerGPUClusters, "power.gpu.clusters"),
            (.powerGPUShared, "power.gpu.shared"),
        ]
        let now = Date(timeIntervalSinceReferenceDate: 100)
        for (kind, rawValue) in expected {
            #expect(kind.rawValue == rawValue)
            let samples = [
                MetricSample(kind: kind, unit: .watts, value: 0, timestamp: now),
                MetricSample.unavailable(kind: kind, unit: .watts, timestamp: now),
            ]
            let encoded = try JSONEncoder().encode(samples)
            #expect(try JSONDecoder().decode([MetricSample].self, from: encoded) == samples)
        }
    }

    @Test func smcSupplyHistoryRemainsSeparateFromEnergyModelHistory() async {
        let recorder = HistoryRecorder()
        let now = Date(timeIntervalSince1970: 200_000)
        let values: [(MetricKind, Double)] = [
            (.powerDRAM, 1),
            (.powerDRAMSupply, 19),
            (.powerDisplay, 2),
            (.powerDisplayBacklight, 3),
            (.powerGPU, 22),
            (.powerGPUClusters, 33),
            (.powerGPUShared, 0),
        ]
        let samples = values.map { kind, value in
            MetricSample(kind: kind, unit: .watts, value: value, timestamp: now)
        }
        #expect(HistoryRecorder.prepareSamples(samples).count == values.count)
        await recorder.ingest(samples)
        await recorder.ingest([
            .unavailable(kind: .powerDRAMSupply, unit: .watts, timestamp: now.addingTimeInterval(0.2)),
        ])

        let buckets = await recorder.buckets(range: .oneHour, now: now.addingTimeInterval(1))
        #expect(buckets.count == values.count)
        for (kind, value) in values {
            let series = buckets.filter { $0.kind == kind }
            #expect(series.count == 1)
            #expect(series.first?.count == 1)
            #expect(series.first?.last == value)
            #expect(series.first?.avg == value)
        }
    }
}
