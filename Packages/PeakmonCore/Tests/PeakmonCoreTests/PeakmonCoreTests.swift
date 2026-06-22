import Foundation
@testable import PeakmonCore
import Testing

@Suite("MetricsStore")
@MainActor
struct MetricsStoreTests {
    @Test func ingestStoresLatest() {
        let store = MetricsStore(historyLimit: 10)
        let sample = MetricSample(kind: .cpuTotal, unit: .percent, value: 12.5)
        store.ingest([sample])
        #expect(store.latest(for: .cpuTotal)?.value == 12.5)
        #expect(store.history(for: .cpuTotal).count == 1)
        #expect(store.latest(for: .memoryUsed) == nil)
    }

    @Test func ingestTrimsToHistoryLimit() {
        let store = MetricsStore(historyLimit: 3)
        for value in 0 ..< 5 {
            store.ingest([
                MetricSample(kind: .cpuTotal, unit: .percent, value: Double(value)),
            ])
        }
        let window = store.history(for: .cpuTotal)
        #expect(window.count == 3)
        #expect(window.map(\.value) == [2, 3, 4])
    }

    @Test func historySuffixReturnsLatestWindow() {
        let store = MetricsStore(historyLimit: 10)
        for value in 0 ..< 5 {
            store.ingest([
                MetricSample(kind: .cpuTotal, unit: .percent, value: Double(value)),
            ])
        }
        #expect(store.historySuffix(for: .cpuTotal, limit: 3).map(\.value) == [2, 3, 4])
        #expect(store.historySuffix(for: .cpuTotal, limit: 5).map(\.value) == [0, 1, 2, 3, 4])
        #expect(store.historySuffix(for: .cpuTotal, limit: 0).isEmpty)
    }

    @Test func historySuffixReadsWrappedRingBuffer() {
        let store = MetricsStore(historyLimit: 4)
        for value in 0 ..< 7 {
            store.ingest([
                MetricSample(kind: .cpuTotal, unit: .percent, value: Double(value)),
            ])
        }
        #expect(store.history(for: .cpuTotal).map(\.value) == [3, 4, 5, 6])
        #expect(store.historySuffix(for: .cpuTotal, limit: 2).map(\.value) == [5, 6])
        #expect(store.historySuffix(for: .cpuTotal, limit: 10).map(\.value) == [3, 4, 5, 6])
    }

    @Test func resetClearsAllKinds() {
        let store = MetricsStore()
        store.ingest([
            MetricSample(kind: .cpuTotal, unit: .percent, value: 10),
            MetricSample(kind: .memoryUsed, unit: .bytes, value: 1024),
        ])
        store.reset()
        #expect(store.latest(for: .cpuTotal) == nil)
        #expect(store.latest(for: .memoryUsed) == nil)
    }
}

@Suite("MetricsScheduler")
struct MetricsSchedulerTests {
    /// Trivial collector that emits a single predetermined sample each tick.
    struct StubCollector: MetricCollector {
        let identifier = "stub"
        let value: Double
        func collect() async throws -> [MetricSample] {
            [MetricSample(kind: .cpuTotal, unit: .percent, value: value)]
        }
    }

    @Test func startProducesSamples() async throws {
        let store = await MetricsStore()
        let scheduler = MetricsScheduler(
            store: store,
            collectors: [StubCollector(value: 42)],
            interval: .milliseconds(20),
        )
        await scheduler.start()
        // Allow at least one tick.
        try await Task.sleep(for: .milliseconds(80))
        await scheduler.stop()
        let latest = await store.latest(for: .cpuTotal)
        #expect(latest?.value == 42)
    }
}
