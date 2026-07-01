//
//  HistorySnapshot.swift
//  PeakmonCore
//
//  Query-side diagnostic history models.
//

import Foundation

public enum HistoryChartMode: String, Hashable, Sendable {
    case line
    case bars
}

public enum HistoryMetricTint: String, Hashable, Sendable {
    case blue
    case green
    case orange
    case indigo
    case teal
    case mint
    case red
    case cyan
    case pink
    case purple
}

public struct HistoryThresholdBand: Hashable, Sendable {
    public let lowerBound: Double
    public let upperBound: Double
    public let tint: HistoryMetricTint

    public init(lowerBound: Double, upperBound: Double, tint: HistoryMetricTint) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.tint = tint
    }
}

public struct HistoryMetricSeriesDefinition: Hashable, Sendable {
    public let label: String
    public let kind: MetricKind
    public let unit: MetricUnit
    public let tint: HistoryMetricTint
    public let fallbackKinds: [MetricKind]

    public init(
        label: String,
        kind: MetricKind,
        unit: MetricUnit,
        tint: HistoryMetricTint,
        fallbackKinds: [MetricKind] = [],
    ) {
        self.label = label
        self.kind = kind
        self.unit = unit
        self.tint = tint
        self.fallbackKinds = fallbackKinds
    }
}

public struct HistoryMetricSeriesSnapshot: Identifiable, Hashable, Sendable {
    public let definition: HistoryMetricSeriesDefinition
    public let buckets: [MetricHistoryBucket]

    public var id: MetricKind { definition.kind }

    public var samples: [MetricSample] {
        buckets.map {
            MetricSample(
                kind: $0.kind,
                unit: $0.unit,
                value: $0.avg,
                timestamp: $0.startDate,
            )
        }
    }

    public var latest: Double? { buckets.last?.last }

    public var average: Double? {
        let totalCount = buckets.reduce(0) { $0 + $1.count }
        guard totalCount > 0 else { return nil }
        let weighted = buckets.reduce(0) { $0 + ($1.avg * Double($1.count)) }
        return weighted / Double(totalCount)
    }

    public var peak: Double? { buckets.map(\.max).max() }

    public func diagnostics(in range: HistoryRange, at now: Date) -> HistorySeriesDiagnostics {
        let lowerBound = now.addingTimeInterval(-range.duration)
        let upperBound = now
        let ordered = buckets
            .filter {
                $0.avg.isFinite
                    && $0.startDate.addingTimeInterval($0.resolution) >= lowerBound
                    && $0.startDate <= upperBound
            }
            .sorted { $0.startDate < $1.startDate }

        var coveredDuration: TimeInterval = 0
        var sampleCount = 0
        var previousEnd: Date?
        var longestGap: TimeInterval?
        var latestSampleDate: Date?

        for bucket in ordered {
            let start = max(bucket.startDate, lowerBound)
            let end = min(bucket.startDate.addingTimeInterval(bucket.resolution), upperBound)
            if end > start {
                coveredDuration += end.timeIntervalSince(start)
            }

            sampleCount += bucket.count
            if let previousEnd, start > previousEnd {
                longestGap = max(longestGap ?? 0, start.timeIntervalSince(previousEnd))
            }
            if previousEnd.map({ end > $0 }) ?? true {
                previousEnd = end
            }
            if latestSampleDate.map({ bucket.lastSampleDate > $0 }) ?? true {
                latestSampleDate = bucket.lastSampleDate
            }
        }

        if let previousEnd, upperBound > previousEnd {
            longestGap = max(longestGap ?? 0, upperBound.timeIntervalSince(previousEnd))
        }

        let coverage = min(max(coveredDuration / max(range.duration, 1), 0), 1)
        let latestAge = latestSampleDate.map { max(0, now.timeIntervalSince($0)) }
        return HistorySeriesDiagnostics(
            sampleCount: sampleCount,
            coverageFraction: coverage,
            longestGap: longestGap,
            latestSampleAge: latestAge,
        )
    }

    public init(definition: HistoryMetricSeriesDefinition, buckets: [MetricHistoryBucket]) {
        self.definition = definition
        self.buckets = buckets
    }
}

public struct HistorySeriesDiagnostics: Hashable, Sendable {
    public let sampleCount: Int
    public let coverageFraction: Double
    public let longestGap: TimeInterval?
    public let latestSampleAge: TimeInterval?

    public init(
        sampleCount: Int,
        coverageFraction: Double,
        longestGap: TimeInterval?,
        latestSampleAge: TimeInterval?,
    ) {
        self.sampleCount = sampleCount
        self.coverageFraction = coverageFraction
        self.longestGap = longestGap
        self.latestSampleAge = latestSampleAge
    }
}

public struct HistoryMetricDiagnostics: Hashable, Sendable {
    public let sampleCount: Int
    public let coverageFraction: Double
    public let longestGap: TimeInterval?
    public let latestSampleAge: TimeInterval?

    public init(
        sampleCount: Int,
        coverageFraction: Double,
        longestGap: TimeInterval?,
        latestSampleAge: TimeInterval?,
    ) {
        self.sampleCount = sampleCount
        self.coverageFraction = coverageFraction
        self.longestGap = longestGap
        self.latestSampleAge = latestSampleAge
    }
}

public struct HistoryMetricSnapshot: Identifiable, Hashable, Sendable {
    public let definition: HistoryMetricDefinition
    public let series: [HistoryMetricSeriesSnapshot]

    public var id: HistoryMetricDefinition { definition }

    public var primarySeries: HistoryMetricSeriesSnapshot? {
        visibleSeries.first
    }

    public var visibleSeries: [HistoryMetricSeriesSnapshot] {
        let populated = series.filter { !$0.buckets.isEmpty }
        return populated.isEmpty ? series : populated
    }

    public var latest: Double? { primarySeries?.latest }
    public var average: Double? { primarySeries?.average }
    public var peak: Double? { primarySeries?.peak }

    public var hasData: Bool {
        series.contains { !$0.buckets.isEmpty }
    }

    public var isMultiSeries: Bool {
        definition.series.count > 1
    }

    public func diagnostics(in range: HistoryRange, at now: Date) -> HistoryMetricDiagnostics {
        let diagnostics = visibleSeries.map { $0.diagnostics(in: range, at: now) }
        let populated = diagnostics.filter { $0.sampleCount > 0 }
        guard !populated.isEmpty else {
            return HistoryMetricDiagnostics(
                sampleCount: 0,
                coverageFraction: 0,
                longestGap: nil,
                latestSampleAge: nil,
            )
        }

        return HistoryMetricDiagnostics(
            sampleCount: populated.reduce(0) { $0 + $1.sampleCount },
            coverageFraction: populated.map(\.coverageFraction).min() ?? 0,
            longestGap: populated.compactMap(\.longestGap).max(),
            latestSampleAge: populated.compactMap(\.latestSampleAge).max(),
        )
    }

    public init(definition: HistoryMetricDefinition, series: [HistoryMetricSeriesSnapshot]) {
        self.definition = definition
        self.series = series
    }
}

public enum HistoryMetricDefinition: String, CaseIterable, Hashable, Sendable {
    case cpu
    case memory
    case power
    case gpu
    case disk
    case network
    case temperature
    case fan

    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .power: "Power"
        case .gpu: "GPU"
        case .disk: "Disk"
        case .network: "Network"
        case .temperature: "Temp"
        case .fan: "Fan"
        }
    }

    public var systemImage: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .power: "bolt.fill"
        case .gpu: "cpu.fill"
        case .disk: "internaldrive"
        case .network: "network"
        case .temperature: "thermometer.medium"
        case .fan: "fan"
        }
    }

    public var tint: HistoryMetricTint {
        switch self {
        case .cpu: .blue
        case .memory: .green
        case .power: .orange
        case .gpu: .indigo
        case .disk: .teal
        case .network: .mint
        case .temperature: .red
        case .fan: .cyan
        }
    }

    public var unit: MetricUnit {
        switch self {
        case .cpu, .memory, .gpu: .percent
        case .power: .watts
        case .disk, .network: .bytesPerSecond
        case .temperature: .celsius
        case .fan: .rpm
        }
    }

    public var chartMode: HistoryChartMode {
        switch self {
        case .disk, .network:
            .bars
        case .cpu, .memory, .power, .gpu, .temperature, .fan:
            .line
        }
    }

    public var thresholdBands: [HistoryThresholdBand] {
        switch self {
        case .cpu, .gpu:
            [
                HistoryThresholdBand(lowerBound: 85, upperBound: 95, tint: .orange),
                HistoryThresholdBand(lowerBound: 95, upperBound: 100, tint: .red),
            ]
        case .memory:
            [HistoryThresholdBand(lowerBound: 80, upperBound: 100, tint: .orange)]
        case .temperature:
            [
                HistoryThresholdBand(lowerBound: 85, upperBound: 90, tint: .orange),
                HistoryThresholdBand(lowerBound: 90, upperBound: 110, tint: .red),
            ]
        case .power, .disk, .network, .fan:
            []
        }
    }

    public var series: [HistoryMetricSeriesDefinition] {
        switch self {
        case .cpu:
            [HistoryMetricSeriesDefinition(label: "CPU", kind: .cpuTotal, unit: .percent, tint: tint)]
        case .memory:
            [HistoryMetricSeriesDefinition(label: "Pressure", kind: .memoryPressure, unit: .percent, tint: tint)]
        case .power:
            [HistoryMetricSeriesDefinition(
                label: "System",
                kind: .powerSystem,
                unit: .watts,
                tint: tint,
                fallbackKinds: [.powerPackage],
            )]
        case .gpu:
            [HistoryMetricSeriesDefinition(label: "GPU", kind: .gpuUtilization, unit: .percent, tint: tint)]
        case .disk:
            [
                HistoryMetricSeriesDefinition(label: "Read", kind: .diskReadRate, unit: .bytesPerSecond, tint: .teal),
                HistoryMetricSeriesDefinition(label: "Write", kind: .diskWriteRate, unit: .bytesPerSecond, tint: .pink),
            ]
        case .network:
            [
                HistoryMetricSeriesDefinition(label: "In", kind: .netInRate, unit: .bytesPerSecond, tint: .mint),
                HistoryMetricSeriesDefinition(label: "Out", kind: .netOutRate, unit: .bytesPerSecond, tint: .purple),
            ]
        case .temperature:
            [
                HistoryMetricSeriesDefinition(label: "CPU", kind: .thermalCPU, unit: .celsius, tint: .red),
                HistoryMetricSeriesDefinition(label: "GPU", kind: .thermalGPU, unit: .celsius, tint: .indigo),
                HistoryMetricSeriesDefinition(label: "Battery", kind: .batteryTemperature, unit: .celsius, tint: .orange),
            ]
        case .fan:
            [
                HistoryMetricSeriesDefinition(label: "Left", kind: .fanLeftRPM, unit: .rpm, tint: .cyan),
                HistoryMetricSeriesDefinition(label: "Right", kind: .fanRightRPM, unit: .rpm, tint: .blue),
            ]
        }
    }

    public var yMax: Double? {
        switch self {
        case .cpu, .memory, .gpu: 100
        case .power, .disk, .network, .temperature, .fan: nil
        }
    }

    public var anomalyKinds: Set<HistoryAnomalyKind> {
        switch self {
        case .cpu: [.cpuSustainedHigh]
        case .memory: [.memoryPressure, .memorySwapHigh]
        case .power: [.powerSustainedHigh]
        case .gpu: [.gpuSustainedHigh, .thermalGPUHigh]
        case .disk: [.diskReadSustainedHigh, .diskWriteSustainedHigh]
        case .network: [.networkInSustainedHigh, .networkOutSustainedHigh]
        case .temperature: [.thermalCPUHigh, .thermalGPUHigh]
        case .fan: []
        }
    }
}

public struct HistorySnapshot: Hashable, Sendable {
    public let capturedAt: Date
    public let metrics: [HistoryMetricSnapshot]
    public let events: [HistoryAnomalyEvent]

    public static let empty = HistorySnapshot(capturedAt: .now, metrics: [], events: [])

    public init(capturedAt: Date, metrics: [HistoryMetricSnapshot], events: [HistoryAnomalyEvent]) {
        self.capturedAt = capturedAt
        self.metrics = metrics
        self.events = events
    }

    public func metric(for definition: HistoryMetricDefinition) -> HistoryMetricSnapshot? {
        metrics.first { $0.definition == definition }
    }

    public func events(for definition: HistoryMetricDefinition) -> [HistoryAnomalyEvent] {
        let kinds = definition.anomalyKinds
        guard !kinds.isEmpty else { return [] }
        return events.filter { kinds.contains($0.kind) }
    }
}

public struct HistoryQueryService: Sendable {
    private let recorder: HistoryRecorder

    public init(recorder: HistoryRecorder) {
        self.recorder = recorder
    }

    public func snapshot(range: HistoryRange, at now: Date = .now) async -> HistorySnapshot {
        let allBuckets = await recorder.buckets(range: range, now: now)
        var bucketsByKey: [HistoryBucketKey: [MetricHistoryBucket]] = [:]
        for bucket in allBuckets {
            bucketsByKey[HistoryBucketKey(kind: bucket.kind, unit: bucket.unit), default: []].append(bucket)
        }

        let metrics = HistoryMetricDefinition.allCases.compactMap { definition -> HistoryMetricSnapshot? in
            let series = definition.series.map { seriesDefinition -> HistoryMetricSeriesSnapshot in
                var buckets = bucketsByKey[
                    HistoryBucketKey(kind: seriesDefinition.kind, unit: seriesDefinition.unit),
                    default: []
                ]
                for fallbackKind in seriesDefinition.fallbackKinds where buckets.isEmpty {
                    buckets = bucketsByKey[
                        HistoryBucketKey(kind: fallbackKind, unit: seriesDefinition.unit),
                        default: []
                    ]
                }
                return HistoryMetricSeriesSnapshot(definition: seriesDefinition, buckets: buckets)
            }
            let snapshot = HistoryMetricSnapshot(definition: definition, series: series)
            return snapshot.hasData ? snapshot : nil
        }

        let events = await recorder.anomalies(in: range, at: now)
            .filter { Self.visibleAnomalyKinds.contains($0.kind) }
        return HistorySnapshot(capturedAt: now, metrics: metrics, events: events)
    }

    private static let visibleAnomalyKinds = Set(HistoryAnomalyKind.allCases)
}
