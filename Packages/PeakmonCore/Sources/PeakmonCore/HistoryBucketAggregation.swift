//
//  HistoryBucketAggregation.swift
//  PeakmonCore
//
//  Pure in-memory aggregation for diagnostic history buckets.
//

import Foundation

struct HistoryBucketKey: Hashable, Sendable {
    let kind: MetricKind
    let unit: MetricUnit
}

typealias HistoryBucketMap = [HistoryRange: [HistoryBucketKey: [Date: MetricHistoryBucket]]]

struct HistoryBucketRecord: Codable, Hashable, Sendable {
    let range: HistoryRange
    let bucket: MetricHistoryBucket
}

struct HistoryBucketReadResult: Sendable {
    let latestByKey: [HistoryBucketKey: MetricHistoryBucket]
    let selectedBuckets: [MetricHistoryBucket]
}

enum HistoryRetention {
    static func duration(for range: HistoryRange, maximumRetentionDuration: TimeInterval) -> TimeInterval {
        min(range.duration, maximumRetentionDuration)
    }

    static func cutoff(
        for range: HistoryRange,
        at now: Date,
        maximumRetentionDuration: TimeInterval,
    ) -> Date {
        now.addingTimeInterval(-duration(for: range, maximumRetentionDuration: maximumRetentionDuration))
    }

    static func bucketOverlapsRetention(
        startDate: Date,
        range: HistoryRange,
        at now: Date,
        maximumRetentionDuration: TimeInterval,
    ) -> Bool {
        let cutoff = cutoff(for: range, at: now, maximumRetentionDuration: maximumRetentionDuration)
        let bucketEnd = startDate.addingTimeInterval(range.bucketInterval)
        return bucketEnd > cutoff && startDate <= now
    }
}

private struct BucketAccumulator {
    let kind: MetricKind
    let unit: MetricUnit
    let resolution: TimeInterval
    let startDate: Date
    let lastSampleDate: Date

    var min: Double
    var max: Double
    var last: Double
    var sum: Double
    var count: Int

    init(sample: MetricSample, resolution: TimeInterval, startDate: Date) {
        self.kind = sample.kind
        self.unit = sample.unit
        self.resolution = resolution
        self.startDate = startDate
        self.lastSampleDate = sample.timestamp
        min = sample.value
        max = sample.value
        last = sample.value
        sum = sample.value
        count = 1
    }

    func build() -> MetricHistoryBucket {
        .init(
            kind: kind,
            unit: unit,
            resolution: resolution,
            startDate: startDate,
            min: min,
            avg: sum / Double(count),
            max: max,
            last: last,
            lastSampleDate: lastSampleDate,
            count: count,
        )
    }
}

struct HistoryBucketAggregation {
    private var bucketedSamples: HistoryBucketMap = Self.emptyBuckets()
    private var dirtyBuckets: HistoryBucketMap = Self.emptyBuckets()
    private var lastPrunedBucketsAt: Date?

    static func emptyBuckets() -> HistoryBucketMap {
        Dictionary(uniqueKeysWithValues: HistoryRange.allCases.map { ($0, [:]) })
    }

    mutating func replaceBuckets(_ buckets: HistoryBucketMap) {
        bucketedSamples = Self.normalizedBuckets(buckets)
        dirtyBuckets = Self.emptyBuckets()
        lastPrunedBucketsAt = nil
    }

    mutating func reset() {
        bucketedSamples = Self.emptyBuckets()
        dirtyBuckets = Self.emptyBuckets()
        lastPrunedBucketsAt = nil
    }

    /// Move the complete read cache to another actor without flattening,
    /// sorting, and rebuilding tens of thousands of bucket records.
    /// Swift dictionaries are copy-on-write, so resetting after the move
    /// keeps startup restoration effectively O(1) beyond the SQLite scan.
    mutating func takeBuckets() -> HistoryBucketMap {
        let buckets = bucketedSamples
        reset()
        return buckets
    }

    @discardableResult
    mutating func ingest(_ orderedSamples: [MetricSample]) -> Date? {
        guard let now = orderedSamples.last?.timestamp else { return nil }

        for sample in orderedSamples {
            for range in HistoryRange.allCases {
                let bucket = ingestBucket(sample: sample, range: range)
                markDirty(bucket, range: range)
            }
        }

        return now
    }

    mutating func buckets(
        for kind: MetricKind? = nil,
        unit: MetricUnit? = nil,
        range: HistoryRange,
        now: Date,
        maximumRetentionDuration: TimeInterval,
        pruneInterval: TimeInterval = 0,
    ) -> [MetricHistoryBucket] {
        pruneIfNeeded(
            at: now,
            maximumRetentionDuration: maximumRetentionDuration,
            interval: pruneInterval,
            force: false,
        )

        guard let perRange = bucketedSamples[range] else { return [] }
        return perRange.values.flatMap { buckets in
            buckets.values
                .filter {
                    HistoryRetention.bucketOverlapsRetention(
                        startDate: $0.startDate,
                        range: range,
                        at: now,
                        maximumRetentionDuration: maximumRetentionDuration,
                    )
                }
                .filter { bucket in kind == nil || bucket.kind == kind }
                .filter { bucket in unit == nil || bucket.unit == unit }
        }
        .sorted {
            if $0.startDate == $1.startDate {
                if $0.kind == $1.kind { return $0.unit.rawValue < $1.unit.rawValue }
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return $0.startDate < $1.startDate
        }
    }

    mutating func read(
        range: HistoryRange,
        selectedKeys: Set<HistoryBucketKey>,
        now: Date,
        maximumRetentionDuration: TimeInterval,
        pruneInterval: TimeInterval = 0,
    ) -> HistoryBucketReadResult {
        pruneIfNeeded(
            at: now,
            maximumRetentionDuration: maximumRetentionDuration,
            interval: pruneInterval,
            force: false,
        )

        let perRange = bucketedSamples[range, default: [:]]
        var latestByKey: [HistoryBucketKey: MetricHistoryBucket] = [:]
        var selectedBuckets: [MetricHistoryBucket] = []

        for (key, buckets) in perRange {
            let retained = buckets.values.filter {
                HistoryRetention.bucketOverlapsRetention(
                    startDate: $0.startDate,
                    range: range,
                    at: now,
                    maximumRetentionDuration: maximumRetentionDuration,
                )
            }
            if let latest = retained.max(by: { $0.lastSampleDate < $1.lastSampleDate }) {
                latestByKey[key] = latest
            }
            if selectedKeys.contains(key) {
                selectedBuckets.append(contentsOf: retained)
            }
        }

        selectedBuckets.sort {
            if $0.startDate == $1.startDate {
                if $0.kind == $1.kind { return $0.unit.rawValue < $1.unit.rawValue }
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return $0.startDate < $1.startDate
        }
        return HistoryBucketReadResult(
            latestByKey: latestByKey,
            selectedBuckets: selectedBuckets,
        )
    }

    mutating func pruneIfNeeded(
        at now: Date,
        maximumRetentionDuration: TimeInterval,
        interval: TimeInterval,
        force: Bool,
    ) {
        if !force, let lastPrunedBucketsAt, now.timeIntervalSince(lastPrunedBucketsAt) < interval {
            return
        }

        pruneBuckets(at: now, maximumRetentionDuration: maximumRetentionDuration)
        pruneDirtyBuckets(at: now, maximumRetentionDuration: maximumRetentionDuration)
        lastPrunedBucketsAt = now
    }

    func hasDirtyBuckets() -> Bool {
        dirtyBuckets.values.contains { perRange in
            perRange.values.contains { !$0.isEmpty }
        }
    }

    func dirtyRecords() -> [HistoryBucketRecord] {
        Self.records(from: dirtyBuckets)
    }

    func allRecords() -> [HistoryBucketRecord] {
        Self.records(from: bucketedSamples)
    }

    mutating func clearDirtyBuckets() {
        dirtyBuckets = Self.emptyBuckets()
    }

    mutating func clearDirtyBuckets(matching records: [HistoryBucketRecord]) {
        for record in records {
            let key = HistoryBucketKey(kind: record.bucket.kind, unit: record.bucket.unit)
            let startDate = record.bucket.startDate
            guard dirtyBuckets[record.range]?[key]?[startDate] == record.bucket else { continue }

            dirtyBuckets[record.range]?[key]?[startDate] = nil
            if dirtyBuckets[record.range]?[key]?.isEmpty == true {
                dirtyBuckets[record.range]?[key] = nil
            }
        }
    }

    mutating func mergeBuckets(_ buckets: HistoryBucketMap) {
        for range in HistoryRange.allCases {
            var perRange = bucketedSamples[range, default: [:]]
            for (key, buckets) in buckets[range, default: [:]] {
                var perSeries = perRange[key, default: [:]]
                for (startDate, bucket) in buckets where perSeries[startDate] == nil {
                    perSeries[startDate] = bucket
                }
                perRange[key] = perSeries
            }
            bucketedSamples[range] = perRange
        }
    }

    static func records(from buckets: HistoryBucketMap) -> [HistoryBucketRecord] {
        HistoryRange.allCases.flatMap { range in
            buckets[range, default: [:]]
                .values
                .flatMap(\.values)
                .sorted {
                    if $0.startDate == $1.startDate {
                        if $0.kind == $1.kind { return $0.unit.rawValue < $1.unit.rawValue }
                        return $0.kind.rawValue < $1.kind.rawValue
                    }
                    return $0.startDate < $1.startDate
                }
                .map { HistoryBucketRecord(range: range, bucket: $0) }
        }
    }

    static func buckets(from records: [HistoryBucketRecord]) -> HistoryBucketMap {
        var buckets = emptyBuckets()
        for record in records {
            let key = HistoryBucketKey(kind: record.bucket.kind, unit: record.bucket.unit)
            buckets[record.range, default: [:]][key, default: [:]][record.bucket.startDate] = record.bucket
        }
        return buckets
    }

    private mutating func ingestBucket(sample: MetricSample, range: HistoryRange) -> MetricHistoryBucket {
        let bucketStart = range.bucketStart(for: sample.timestamp)
        let key = HistoryBucketKey(kind: sample.kind, unit: sample.unit)

        var perRange = bucketedSamples[range, default: [:]]
        var perSeries = perRange[key, default: [:]]
        let bucket: MetricHistoryBucket
        if let current = perSeries[bucketStart] {
            bucket = aggregate(current, with: sample)
        } else {
            let accumulator = BucketAccumulator(
                sample: sample,
                resolution: range.bucketInterval,
                startDate: bucketStart,
            )
            bucket = accumulator.build()
        }
        perSeries[bucketStart] = bucket
        perRange[key] = perSeries
        bucketedSamples[range] = perRange
        return bucket
    }

    private mutating func pruneBuckets(at now: Date, maximumRetentionDuration: TimeInterval) {
        for range in HistoryRange.allCases {
            var perRange = bucketedSamples[range, default: [:]]
            for (key, buckets) in perRange {
                let filtered = buckets.filter {
                    HistoryRetention.bucketOverlapsRetention(
                        startDate: $0.key,
                        range: range,
                        at: now,
                        maximumRetentionDuration: maximumRetentionDuration,
                    )
                }
                perRange[key] = filtered.isEmpty ? nil : filtered
            }
            bucketedSamples[range] = perRange
        }
    }

    private mutating func pruneDirtyBuckets(at now: Date, maximumRetentionDuration: TimeInterval) {
        for range in HistoryRange.allCases {
            var perRange = dirtyBuckets[range, default: [:]]
            for (key, buckets) in perRange {
                let filtered = buckets.filter { startDate, bucket in
                    guard HistoryRetention.bucketOverlapsRetention(
                        startDate: startDate,
                        range: range,
                        at: now,
                        maximumRetentionDuration: maximumRetentionDuration,
                    ) else {
                        return false
                    }
                    return bucketedSamples[range]?[key]?[startDate] == bucket
                }
                perRange[key] = filtered.isEmpty ? nil : filtered
            }
            dirtyBuckets[range] = perRange
        }
    }

    private func aggregate(_ bucket: MetricHistoryBucket, with sample: MetricSample) -> MetricHistoryBucket {
        let newCount = bucket.count + 1
        let isNewestSample = sample.timestamp >= bucket.lastSampleDate
        return MetricHistoryBucket(
            kind: bucket.kind,
            unit: bucket.unit,
            resolution: bucket.resolution,
            startDate: bucket.startDate,
            min: min(bucket.min, sample.value),
            avg: (bucket.avg * Double(bucket.count) + sample.value) / Double(newCount),
            max: max(bucket.max, sample.value),
            last: isNewestSample ? sample.value : bucket.last,
            lastSampleDate: isNewestSample ? sample.timestamp : bucket.lastSampleDate,
            count: newCount,
        )
    }

    private mutating func markDirty(_ bucket: MetricHistoryBucket, range: HistoryRange) {
        let key = HistoryBucketKey(kind: bucket.kind, unit: bucket.unit)
        var perRange = dirtyBuckets[range, default: [:]]
        var perSeries = perRange[key, default: [:]]
        perSeries[bucket.startDate] = bucket
        perRange[key] = perSeries
        dirtyBuckets[range] = perRange
    }

    private static func normalizedBuckets(_ buckets: HistoryBucketMap) -> HistoryBucketMap {
        var normalized = emptyBuckets()
        for range in HistoryRange.allCases {
            normalized[range] = buckets[range, default: [:]]
        }
        return normalized
    }
}
