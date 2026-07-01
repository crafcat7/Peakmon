//
//  HistoryRecorder.swift
//  PeakmonCore
//
//  Ingestion facade for lightweight history + anomaly detection.
//

import Foundation

/// Lightweight recorder for historical buckets and lightweight anomaly
/// inference that can be consumed directly by UI without a persistence
/// layer.
public actor HistoryRecorder {
    public static let defaultRecordedKinds: Set<MetricKind> = [
        .cpuTotal,
        .memoryUsed,
        .memoryWired,
        .memoryCompressed,
        .memorySwapUsed,
        .memoryPressure,
        .memoryPressureLevel,
        .batteryTemperature,
        .gpuUtilization,
        .powerSystem,
        .powerPackage,
        .powerCPU,
        .powerGPU,
        .powerDRAM,
        .powerDisplay,
        .diskReadRate,
        .diskWriteRate,
        .netInRate,
        .netOutRate,
        .thermalCPU,
        .thermalGPU,
        .fanLeftRPM,
        .fanRightRPM,
    ]

    private let store: HistoryStore
    private let recordedKinds: Set<MetricKind>
    private var anomalyEngine = HistoryAnomalyEngine()

    public init(
        store: HistoryStore = HistoryStore(),
        recordedKinds: Set<MetricKind> = HistoryRecorder.defaultRecordedKinds,
    ) {
        self.store = store
        self.recordedKinds = recordedKinds
    }

    public static func prepareSamples(
        _ samples: [MetricSample],
        recordedKinds: Set<MetricKind> = HistoryRecorder.defaultRecordedKinds,
    ) -> [MetricSample] {
        samples
            .filter { shouldRecord($0, recordedKinds: recordedKinds) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    public static func shouldRecord(
        _ sample: MetricSample,
        recordedKinds: Set<MetricKind> = HistoryRecorder.defaultRecordedKinds,
    ) -> Bool {
        recordedKinds.contains(sample.kind) && sample.value.isFinite
    }

    /// Ingest samples, update short/long range aggregates, and emit
    /// lightweight anomalies when needed.
    public func ingest(_ samples: [MetricSample]) async {
        await ingestPrepared(Self.prepareSamples(samples, recordedKinds: recordedKinds))
    }

    /// Ingest samples that have already been filtered to recorded metric
    /// kinds, finite numeric values, and ascending timestamp order.
    ///
    /// This keeps the scheduler -> history hot path from allocating and
    /// sorting the same batch in multiple layers.
    public func ingestPrepared(_ ordered: [MetricSample]) async {
        guard !ordered.isEmpty else { return }
        await store.ingestPrepared(ordered)
        anomalyEngine.ingest(ordered)
    }

    /// Return buckets for history charts.
    public func buckets(
        for kind: MetricKind? = nil,
        unit: MetricUnit? = nil,
        range: HistoryRange,
        now: Date = .now,
    ) async -> [MetricHistoryBucket] {
        await store.buckets(
            for: kind,
            unit: unit,
            range: range,
            now: now,
        )
    }

    /// Return detected anomalies within the requested window.
    public func anomalies(in range: HistoryRange, at now: Date = .now) -> [HistoryAnomalyEvent] {
        anomalyEngine.events(in: range, at: now)
    }

    /// Wipe both history and anomaly state.
    public func reset() async {
        anomalyEngine.reset()
        await store.reset()
    }

    /// Persist any pending history data immediately.
    public func flush() async {
        await store.flush()
    }
}
