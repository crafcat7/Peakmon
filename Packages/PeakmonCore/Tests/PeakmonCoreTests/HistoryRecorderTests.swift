//
//  HistoryRecorderTests.swift
//  PeakmonCore
//

import Foundation
@testable import PeakmonCore
import SQLite3
import Testing

@Suite("HistoryRecorder")
struct HistoryRecorderTests {
    @Test
    func oneHourBucketsUseFineGrainAggregation() async throws {
        let store = HistoryStore()
        let now = Date(timeIntervalSince1970: 200_000)
        let samples = (0..<1300).map { offset in
            MetricSample(
                kind: .cpuTotal,
                unit: .percent,
                value: Double(offset),
                timestamp: now.addingTimeInterval(Double(offset)),
            )
        }

        await store.ingest(samples)
        let buckets = await store.buckets(
            for: .cpuTotal,
            unit: .percent,
            range: .oneHour,
            now: now.addingTimeInterval(1_300),
        )

        #expect(buckets.count == 1300)
        #expect(buckets.first?.resolution == 1)
        #expect(buckets.first?.count == 1)
        #expect(buckets.first?.min == 0)
        #expect(buckets.last?.max == 1299)
    }

    @Test
    func longRangeBucketsAggregateByTime() async throws {
        let store = HistoryStore()
        let now = Date(timeIntervalSince1970: 400_000)
        let samples = (0..<1300).map { offset in
            MetricSample(
                kind: .memoryUsed,
                unit: .bytes,
                value: 1000,
                timestamp: now.addingTimeInterval(Double(offset)),
            )
        }

        await store.ingest(samples)
        let sixHour = await store.buckets(
            for: .memoryUsed,
            unit: .bytes,
            range: .sixHours,
            now: now.addingTimeInterval(1_300),
        )
        let day = await store.buckets(
            for: .memoryUsed,
            unit: .bytes,
            range: .twentyFourHours,
            now: now.addingTimeInterval(1_300),
        )

        let firstOffsetSample = now
        let lastOffsetSample = now.addingTimeInterval(1_299)
        let firstSixHourBucket = HistoryRange.sixHours.bucketStart(for: firstOffsetSample)
        let lastSixHourBucket = HistoryRange.sixHours.bucketStart(for: lastOffsetSample)
        let expectedSixHourBucketCount = Int(
            (lastSixHourBucket.timeIntervalSince(firstSixHourBucket) / 10).rounded(.towardZero),
        ) + 1
        let firstDayBucket = HistoryRange.twentyFourHours.bucketStart(for: firstOffsetSample)
        let lastDayBucket = HistoryRange.twentyFourHours.bucketStart(for: lastOffsetSample)
        let expectedDayBucketCount = Int(
            (lastDayBucket.timeIntervalSince(firstDayBucket) / 60).rounded(.towardZero),
        ) + 1

        #expect(sixHour.count == expectedSixHourBucketCount)
        #expect(sixHour.allSatisfy { $0.resolution == 10 })
        #expect(sixHour.allSatisfy { $0.count > 0 && $0.count <= 10 })

        #expect(day.count == expectedDayBucketCount)
        #expect(day.allSatisfy { $0.resolution == 60 })
        #expect(day.allSatisfy { $0.count > 0 && $0.count <= 60 })
    }

    @Test
    func aggregationEngineOwnsBucketRetentionAndDirtyRecords() async throws {
        var aggregation = HistoryBucketAggregation()
        let now = Date(timeIntervalSince1970: 450_000)
        let samples = [
            MetricSample(
                kind: .cpuTotal,
                unit: .percent,
                value: 99,
                timestamp: now.addingTimeInterval(-3_700),
            ),
            MetricSample(
                kind: .cpuTotal,
                unit: .percent,
                value: 20,
                timestamp: now.addingTimeInterval(-5),
            ),
            MetricSample(
                kind: .cpuTotal,
                unit: .percent,
                value: 30,
                timestamp: now,
            ),
        ]

        aggregation.ingest(samples)
        let oneHourBuckets = aggregation.buckets(
            for: .cpuTotal,
            unit: .percent,
            range: .oneHour,
            now: now,
            maximumRetentionDuration: HistoryRange.maximumDuration,
        )
        let sixHourBuckets = aggregation.buckets(
            for: .cpuTotal,
            unit: .percent,
            range: .sixHours,
            now: now,
            maximumRetentionDuration: HistoryRange.maximumDuration,
        )

        #expect(oneHourBuckets.count == 2)
        #expect(oneHourBuckets.map(\.last) == [20, 30])
        #expect(sixHourBuckets.contains { $0.max == 99 })
        #expect(aggregation.dirtyRecords().allSatisfy { record in
            record.range != .oneHour || record.bucket.max != 99
        })

        aggregation.clearDirtyBuckets()
        #expect(!aggregation.hasDirtyBuckets())
    }

    @Test
    func historyQueryServiceBuildsMetricSnapshotsAndEvents() async throws {
        let recorder = HistoryRecorder()
        let now = Date(timeIntervalSince1970: 470_000)
        await recorder.ingest([
            MetricSample(kind: .powerPackage, unit: .watts, value: 17, timestamp: now),
            MetricSample(kind: .cpuTotal, unit: .percent, value: 92, timestamp: now),
            MetricSample(kind: .cpuTotal, unit: .percent, value: 92, timestamp: now.addingTimeInterval(6)),
        ])

        let snapshot = await HistoryQueryService(recorder: recorder).snapshot(
            range: .oneHour,
            at: now.addingTimeInterval(7),
        )

        let power = try #require(snapshot.metric(for: .power))
        let cpu = try #require(snapshot.metric(for: .cpu))
        let cpuDiagnostics = cpu.diagnostics(in: .oneHour, at: now.addingTimeInterval(7))
        let cpuEvents = snapshot.events(for: .cpu)
        #expect(power.latest == 17)
        #expect(power.primarySeries?.definition.kind == .powerSystem)
        #expect(power.primarySeries?.buckets.first?.kind == .powerPackage)
        #expect(cpuDiagnostics.sampleCount == 2)
        #expect(abs(cpuDiagnostics.coverageFraction - (2.0 / 3_600.0)) < 0.0001)
        #expect(cpuDiagnostics.longestGap == 5)
        #expect(cpuDiagnostics.latestSampleAge == 1)
        #expect(cpuEvents.count == 1)
        #expect(cpuEvents[0].kind == .cpuSustainedHigh)
        #expect(snapshot.events(for: .fan).isEmpty)
    }

    @Test
    func anomalyEventsGenerateAndMerge() async throws {
        let recorder = HistoryRecorder()
        let now = Date(timeIntervalSince1970: 500_000)
        let cpuBurst = (0..<6).map { offset in
            MetricSample(
                kind: .cpuTotal,
                unit: .percent,
                value: 92,
                timestamp: now.addingTimeInterval(Double(offset)),
            )
        }
        let cpuReset = [
            MetricSample(
                kind: .cpuTotal,
                unit: .percent,
                value: 40,
                timestamp: now.addingTimeInterval(6),
            ),
        ]
        let cpuBurstTwo = (20..<26).map { offset in
            MetricSample(
                kind: .cpuTotal,
                unit: .percent,
                value: 97,
                timestamp: now.addingTimeInterval(Double(offset)),
            )
        }
        let cpuClose = [
            MetricSample(
                kind: .cpuTotal,
                unit: .percent,
                value: 40,
                timestamp: now.addingTimeInterval(26),
            ),
        ]
        let memoryPressure = (40..<46).map { offset in
            MetricSample(
                kind: .memoryPressureLevel,
                unit: .count,
                value: 4,
                timestamp: now.addingTimeInterval(Double(offset)),
            )
        }
        let memoryClose = [
            MetricSample(
                kind: .memoryPressureLevel,
                unit: .count,
                value: 1,
                timestamp: now.addingTimeInterval(46),
            ),
        ]

        await recorder.ingest(cpuBurst)
        await recorder.ingest(cpuReset)
        await recorder.ingest(cpuBurstTwo)
        await recorder.ingest(cpuClose)
        await recorder.ingest(memoryPressure)
        await recorder.ingest(memoryClose)

        let events = await recorder.anomalies(in: .oneHour, at: now.addingTimeInterval(46))
        let cpuEvents = events.filter { $0.kind == .cpuSustainedHigh }
        let memoryEvents = events.filter { $0.kind == .memoryPressure }
        #expect(cpuEvents.count == 1)
        #expect(memoryEvents.count == 1)
        #expect(cpuEvents[0].startDate == now)
        #expect(cpuEvents[0].endDate == now.addingTimeInterval(25))
        #expect(cpuEvents[0].severity == .high)
        #expect(cpuEvents[0].peakValue == 97)
        #expect(memoryEvents[0].severity == .medium)
        #expect(memoryEvents[0].peakValue == 4)
    }

    @Test
    func openAnomalyIsQueryableAfterMinimumDuration() async throws {
        let recorder = HistoryRecorder()
        let now = Date(timeIntervalSince1970: 550_000)
        let cpuBurst = (0..<8).map { offset in
            MetricSample(
                kind: .cpuTotal,
                unit: .percent,
                value: 88,
                timestamp: now.addingTimeInterval(Double(offset)),
            )
        }

        await recorder.ingest(cpuBurst)

        let events = await recorder.anomalies(in: .oneHour, at: now.addingTimeInterval(8))
        #expect(events.count == 1)
        #expect(events[0].kind == .cpuSustainedHigh)
        #expect(events[0].endDate == now.addingTimeInterval(8))
        #expect(events[0].severity == .medium)
    }

    @Test
    func defaultRecorderRecordsDiagnosticHistoryMetrics() async throws {
        let recorder = HistoryRecorder()
        let now = Date(timeIntervalSince1970: 575_000)
        let recordedSamples: [(MetricKind, MetricUnit, Double)] = [
            (.cpuTotal, .percent, 40),
            (.memoryUsed, .bytes, 8_000_000_000),
            (.memoryWired, .bytes, 2_000_000_000),
            (.memoryCompressed, .bytes, 1_000_000_000),
            (.memorySwapUsed, .bytes, 512_000_000),
            (.memoryPressure, .percent, 58),
            (.memoryPressureLevel, .count, 1),
            (.batteryTemperature, .celsius, 34),
            (.gpuUtilization, .percent, 80),
            (.powerSystem, .watts, 24),
            (.powerPackage, .watts, 18),
            (.powerCPU, .watts, 6),
            (.powerGPU, .watts, 7),
            (.powerDRAM, .watts, 3),
            (.powerDisplay, .watts, 2),
            (.diskReadRate, .bytesPerSecond, 4096),
            (.diskWriteRate, .bytesPerSecond, 2048),
            (.netInRate, .bytesPerSecond, 8192),
            (.netOutRate, .bytesPerSecond, 1024),
            (.thermalCPU, .celsius, 72),
            (.thermalGPU, .celsius, 68),
            (.fanLeftRPM, .rpm, 1400),
            (.fanRightRPM, .rpm, 1320),
        ]
        let ignoredSamples: [(MetricKind, MetricUnit, Double)] = [
            (.diskUsed, .bytes, 512_000),
            (.gpuMemoryInUse, .bytes, 256_000),
            (.batteryCycleCount, .count, 120),
        ]
        let samples = (recordedSamples + ignoredSamples).map { kind, unit, value in
            MetricSample(kind: kind, unit: unit, value: value, timestamp: now)
        }

        await recorder.ingest(samples)

        #expect(HistoryRecorder.defaultRecordedKinds == Set(recordedSamples.map { $0.0 }))

        for (kind, unit, _) in recordedSamples {
            let buckets = await recorder.buckets(
                for: kind,
                unit: unit,
                range: .oneHour,
                now: now.addingTimeInterval(7),
            )
            #expect(buckets.count == 1)
        }

        for (kind, unit, _) in ignoredSamples {
            let buckets = await recorder.buckets(
                for: kind,
                unit: unit,
                range: .oneHour,
                now: now.addingTimeInterval(7),
            )
            #expect(buckets.isEmpty)
        }
    }

    @Test
    func thermalAnomalyGeneratesAfterSustainedHighTemperature() async throws {
        let recorder = HistoryRecorder()
        let now = Date(timeIntervalSince1970: 575_100)
        let hotSamples = (0..<7).map { offset in
            MetricSample(
                kind: .thermalCPU,
                unit: .celsius,
                value: 92,
                timestamp: now.addingTimeInterval(Double(offset)),
            )
        }
        let coolSample = MetricSample(
            kind: .thermalCPU,
            unit: .celsius,
            value: 65,
            timestamp: now.addingTimeInterval(7),
        )

        await recorder.ingest(hotSamples + [coolSample])

        let events = await recorder.anomalies(in: .oneHour, at: now.addingTimeInterval(7))
        #expect(events.count == 1)
        #expect(events[0].kind == .thermalCPUHigh)
        #expect(events[0].severity == .medium)
        #expect(events[0].peakValue == 92)
    }

    @Test
    func anomaliesRequireMatchingUnitsAndMultipleSamples() async throws {
        let recorder = HistoryRecorder()
        let now = Date(timeIntervalSince1970: 575_200)
        await recorder.ingest([
            MetricSample(
                kind: .cpuTotal,
                unit: .count,
                value: 99,
                timestamp: now,
            ),
            MetricSample(
                kind: .cpuTotal,
                unit: .percent,
                value: 99,
                timestamp: now.addingTimeInterval(20),
            ),
        ])

        let events = await recorder.anomalies(in: .oneHour, at: now.addingTimeInterval(25))
        #expect(events.isEmpty)
    }

    @Test
    func anomalyCooldownDoesNotExtendReportedDuration() async throws {
        let recorder = HistoryRecorder()
        let now = Date(timeIntervalSince1970: 575_250)
        await recorder.ingest([
            MetricSample(kind: .cpuTotal, unit: .percent, value: 88, timestamp: now),
            MetricSample(kind: .cpuTotal, unit: .percent, value: 88, timestamp: now.addingTimeInterval(6)),
            MetricSample(kind: .cpuTotal, unit: .percent, value: 75, timestamp: now.addingTimeInterval(20)),
        ])

        let coolingEvents = await recorder.anomalies(in: .oneHour, at: now.addingTimeInterval(60))
        #expect(coolingEvents.count == 1)
        #expect(coolingEvents[0].kind == .cpuSustainedHigh)
        #expect(coolingEvents[0].endDate == now.addingTimeInterval(6))

        await recorder.ingest([
            MetricSample(kind: .cpuTotal, unit: .percent, value: 60, timestamp: now.addingTimeInterval(61)),
        ])

        let closedEvents = await recorder.anomalies(in: .oneHour, at: now.addingTimeInterval(62))
        #expect(closedEvents.count == 1)
        #expect(closedEvents[0].endDate == now.addingTimeInterval(6))
    }

    @Test
    func anomalyMergeWorksAcrossInterleavedKinds() async throws {
        let recorder = HistoryRecorder()
        let now = Date(timeIntervalSince1970: 575_275)
        await recorder.ingest([
            MetricSample(kind: .cpuTotal, unit: .percent, value: 90, timestamp: now),
            MetricSample(kind: .cpuTotal, unit: .percent, value: 90, timestamp: now.addingTimeInterval(6)),
            MetricSample(kind: .cpuTotal, unit: .percent, value: 40, timestamp: now.addingTimeInterval(7)),
            MetricSample(kind: .memoryPressureLevel, unit: .count, value: 4, timestamp: now.addingTimeInterval(10)),
            MetricSample(kind: .memoryPressureLevel, unit: .count, value: 4, timestamp: now.addingTimeInterval(16)),
            MetricSample(kind: .memoryPressureLevel, unit: .count, value: 1, timestamp: now.addingTimeInterval(17)),
            MetricSample(kind: .cpuTotal, unit: .percent, value: 90, timestamp: now.addingTimeInterval(25)),
            MetricSample(kind: .cpuTotal, unit: .percent, value: 90, timestamp: now.addingTimeInterval(31)),
            MetricSample(kind: .cpuTotal, unit: .percent, value: 40, timestamp: now.addingTimeInterval(32)),
        ])

        let events = await recorder.anomalies(in: .oneHour, at: now.addingTimeInterval(40))
        let cpuEvents = events.filter { $0.kind == .cpuSustainedHigh }
        let memoryEvents = events.filter { $0.kind == .memoryPressure }
        #expect(cpuEvents.count == 1)
        #expect(memoryEvents.count == 1)
        #expect(cpuEvents[0].startDate == now)
        #expect(cpuEvents[0].endDate == now.addingTimeInterval(31))
    }

    @Test
    func expandedAnomalyRulesGenerateDiagnosticEvents() async throws {
        let recorder = HistoryRecorder()
        let now = Date(timeIntervalSince1970: 575_300)
        let megabyte = 1_024.0 * 1_024.0
        let burst: [(HistoryAnomalyKind, MetricKind, MetricUnit, Double, Double)] = [
            (.gpuSustainedHigh, .gpuUtilization, .percent, 94, 20),
            (.memorySwapHigh, .memorySwapUsed, .bytes, 3_000 * megabyte, 40),
            (.powerSustainedHigh, .powerSystem, .watts, 42, 60),
            (.diskReadSustainedHigh, .diskReadRate, .bytesPerSecond, 120 * megabyte, 80),
            (.diskWriteSustainedHigh, .diskWriteRate, .bytesPerSecond, 120 * megabyte, 100),
            (.networkInSustainedHigh, .netInRate, .bytesPerSecond, 30 * megabyte, 120),
            (.networkOutSustainedHigh, .netOutRate, .bytesPerSecond, 30 * megabyte, 140),
            (.thermalGPUHigh, .thermalGPU, .celsius, 92, 160),
        ]

        for item in burst {
            let (_, kind, unit, value, startOffset) = item
            let start = now.addingTimeInterval(startOffset)
            let samples = [
                MetricSample(kind: kind, unit: unit, value: value, timestamp: start),
                MetricSample(kind: kind, unit: unit, value: value, timestamp: start.addingTimeInterval(11)),
                MetricSample(kind: kind, unit: unit, value: 0, timestamp: start.addingTimeInterval(12)),
            ]
            await recorder.ingest(samples)
        }

        let events = await recorder.anomalies(in: .oneHour, at: now.addingTimeInterval(180))
        for (expectedKind, _, _, _, _) in burst {
            #expect(events.contains { $0.kind == expectedKind })
        }
        #expect(events.first { $0.kind == .powerSustainedHigh }?.severity == .medium)
        #expect(events.first { $0.kind == .memorySwapHigh }?.severity == .medium)
    }

    @Test
    func trimsExpiredAnomalyEvents() async throws {
        let recorder = HistoryRecorder()
        let now = Date(timeIntervalSince1970: 700_000)
        let oldStart = now.addingTimeInterval(-HistoryRange.twentyFourHours.duration - 120)
        let oldBurst = (0..<7).map { offset in
            MetricSample(
                kind: .cpuTotal,
                unit: .percent,
                value: 90,
                timestamp: oldStart.addingTimeInterval(Double(offset)),
            )
        }
        let oldClose = MetricSample(
            kind: .cpuTotal,
            unit: .percent,
            value: 10,
            timestamp: oldStart.addingTimeInterval(7),
        )
        let freshBurst = (0..<7).map { offset in
            MetricSample(
                kind: .cpuTotal,
                unit: .percent,
                value: 90,
                timestamp: now.addingTimeInterval(Double(offset)),
            )
        }
        let freshClose = MetricSample(
            kind: .cpuTotal,
            unit: .percent,
            value: 10,
            timestamp: now.addingTimeInterval(7),
        )

        await recorder.ingest(oldBurst + [oldClose])
        await recorder.ingest(freshBurst + [freshClose])

        let events = await recorder.anomalies(in: .twentyFourHours, at: now.addingTimeInterval(7))
        #expect(events.count == 1)
        #expect(events[0].startDate == now)
    }

    @Test
    func trimsExpiredData() async throws {
        let store = HistoryStore()
        let now = Date(timeIntervalSince1970: 600_000)
        let oldSample = MetricSample(
            kind: .cpuTotal,
            unit: .percent,
            value: 20,
            timestamp: now.addingTimeInterval(-90_000),
        )
        let freshSample = MetricSample(
            kind: .cpuTotal,
            unit: .percent,
            value: 42,
            timestamp: now.addingTimeInterval(-1_500),
        )
        await store.ingest([oldSample, freshSample])

        let oneHourBuckets = await store.buckets(
            for: .cpuTotal,
            unit: .percent,
            range: .oneHour,
            now: now,
        )
        let dayBuckets = await store.buckets(
            for: .cpuTotal,
            unit: .percent,
            range: .twentyFourHours,
            now: now,
        )
        #expect(oneHourBuckets.count == 1)
        #expect(dayBuckets.count == 1)
        #expect(oneHourBuckets.first?.max == 42)
        #expect(dayBuckets.first?.max == 42)
    }

    @Test
    func historyKeepsBucketsOverlappingLeftEdge() async throws {
        let store = HistoryStore()
        let range = HistoryRange.twentyFourHours
        let now = range.bucketStart(for: Date()).addingTimeInterval(range.bucketInterval / 2)
        let cutoff = now.addingTimeInterval(-range.duration)
        let sampleTime = cutoff.addingTimeInterval(1)
        let bucketStart = range.bucketStart(for: sampleTime)

        #expect(bucketStart < cutoff)

        await store.ingest([
            MetricSample(
                kind: .cpuTotal,
                unit: .percent,
                value: 41,
                timestamp: sampleTime,
            ),
        ])

        let buckets = await store.buckets(
            for: .cpuTotal,
            unit: .percent,
            range: range,
            now: now,
        )
        #expect(buckets.count == 1)
        #expect(buckets.first?.startDate == bucketStart)
    }

    @Test
    func persistedStoreRestoresBucketsAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeakmonHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let now = Date()
        let store = HistoryStore(persistenceURL: url, persistenceSaveInterval: 3_600)
        let samples = (0..<60).map { offset in
            MetricSample(
                kind: .cpuTotal,
                unit: .percent,
                value: Double(offset),
                timestamp: now.addingTimeInterval(Double(offset - 59)),
            )
        }

        await store.ingest(samples)
        await store.flush()

        let restoredStore = HistoryStore(persistenceURL: url, persistenceSaveInterval: 3_600)
        let restoredBuckets = await restoredStore.buckets(
            for: .cpuTotal,
            unit: .percent,
            range: .oneHour,
            now: now,
        )

        #expect(restoredBuckets.count == 60)
        #expect(restoredBuckets.first?.min == 0)
        #expect(restoredBuckets.last?.max == 59)
    }

    @Test
    func persistedStoreIgnoresOutOfWindowBucketsAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeakmonHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        let databaseURL = url.deletingPathExtension().appendingPathExtension("sqlite")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let oldStore = HistoryStore(persistenceURL: url, persistenceSaveInterval: 3_600)
        await oldStore.ingest([
            MetricSample(
                kind: .cpuTotal,
                unit: .percent,
                value: 20,
                timestamp: Date().addingTimeInterval(-HistoryRange.twentyFourHours.duration - 120),
            ),
        ])
        await oldStore.flush()

        let oldRestoredStore = HistoryStore(persistenceURL: url, persistenceSaveInterval: 3_600)
        let oldRestoredBuckets = await oldRestoredStore.buckets(
            for: .cpuTotal,
            unit: .percent,
            range: .twentyFourHours,
        )
        #expect(oldRestoredBuckets.isEmpty)
        #expect(sqliteRowCount(at: databaseURL) == 0)

        let futureStore = HistoryStore(persistenceURL: url, persistenceSaveInterval: 3_600)
        await futureStore.ingest([
            MetricSample(
                kind: .cpuTotal,
                unit: .percent,
                value: 60,
                timestamp: Date().addingTimeInterval(3_600),
            ),
        ])
        await futureStore.flush()

        let futureRestoredStore = HistoryStore(persistenceURL: url, persistenceSaveInterval: 3_600)
        let futureRestoredBuckets = await futureRestoredStore.buckets(
            for: .cpuTotal,
            unit: .percent,
            range: .oneHour,
        )
        #expect(futureRestoredBuckets.isEmpty)
        #expect(sqliteRowCount(at: databaseURL) == 0)
    }

    @Test
    func sqliteMaintenancePrunesExpiredRowsFromDatabase() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeakmonHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        let databaseURL = url.deletingPathExtension().appendingPathExtension("sqlite")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let store = HistoryStore(
            persistenceURL: url,
            persistenceSaveInterval: 0,
            persistenceCompactionInterval: 0,
        )
        await store.ingest([
            MetricSample(
                kind: .cpuTotal,
                unit: .percent,
                value: 20,
                timestamp: Date().addingTimeInterval(-HistoryRange.twentyFourHours.duration - 120),
            ),
        ])

        #expect(sqliteRowCount(at: databaseURL) == 0)
    }

    @Test
    func sqliteMaintenanceKeepsRowsOverlappingLeftEdge() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeakmonHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        let databaseURL = url.deletingPathExtension().appendingPathExtension("sqlite")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let range = HistoryRange.twentyFourHours
        let now = range.bucketStart(for: Date()).addingTimeInterval(range.bucketInterval / 2)
        let cutoff = now.addingTimeInterval(-range.duration)
        let sampleTime = cutoff.addingTimeInterval(1)
        let bucketStart = range.bucketStart(for: sampleTime)
        let store = HistoryStore(
            persistenceURL: url,
            persistenceSaveInterval: 0,
            persistenceCompactionInterval: 0,
        )

        #expect(bucketStart < cutoff)

        await store.ingest([
            MetricSample(
                kind: .cpuTotal,
                unit: .percent,
                value: 39,
                timestamp: sampleTime,
            ),
        ])

        #expect(sqliteRowCount(at: databaseURL) == 1)

        let restoredStore = HistoryStore(persistenceURL: url, persistenceSaveInterval: 3_600)
        let buckets = await restoredStore.buckets(
            for: .cpuTotal,
            unit: .percent,
            range: range,
            now: now,
        )
        #expect(buckets.count == 1)
        #expect(buckets.first?.startDate == bucketStart)
    }

    @Test
    func sqliteMaintenanceTruncatesWALWhenLimitIsLow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeakmonHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        let databaseURL = url.deletingPathExtension().appendingPathExtension("sqlite")
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let now = Date()
        let store = HistoryStore(
            persistenceURL: url,
            persistenceSaveInterval: 0,
            persistenceCompactionInterval: 0,
            persistenceCompactionLogByteLimit: 1,
        )
        let samples = (0..<180).map { offset in
            MetricSample(
                kind: .cpuTotal,
                unit: .percent,
                value: Double(offset % 100),
                timestamp: now.addingTimeInterval(Double(offset - 180)),
            )
        }
        await store.ingest(samples)

        #expect(fileSize(at: walURL) <= 4_096)
    }

    @Test
    func persistedStoreResetDeletesSavedBuckets() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeakmonHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let store = HistoryStore(persistenceURL: url, persistenceSaveInterval: 3_600)
        await store.ingest([
            MetricSample(kind: .cpuTotal, unit: .percent, value: 44, timestamp: .now),
        ])
        await store.flush()
        #expect(FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("sqlite").path))

        await store.reset()

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("log").path))
        let restoredStore = HistoryStore(persistenceURL: url, persistenceSaveInterval: 3_600)
        let restoredBuckets = await restoredStore.buckets(
            for: .cpuTotal,
            unit: .percent,
            range: .oneHour,
        )
        #expect(restoredBuckets.isEmpty)
    }

    @Test
    func persistedStoreStartsEmptyWhenFileIsCorrupt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeakmonHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: url)

        let store = HistoryStore(persistenceURL: url, persistenceSaveInterval: 3_600)
        let buckets = await store.buckets(
            for: .cpuTotal,
            unit: .percent,
            range: .oneHour,
        )
        #expect(buckets.isEmpty)
    }

    @Test
    func sqliteUpsertKeepsBucketIdempotent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeakmonHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let bucketStart = HistoryRange.oneHour.bucketStart(for: Date().addingTimeInterval(-10))
        let now = bucketStart.addingTimeInterval(0.2)
        let store = HistoryStore(persistenceURL: url, persistenceSaveInterval: 3_600)
        await store.ingest([
            MetricSample(kind: .cpuTotal, unit: .percent, value: 10, timestamp: now),
            MetricSample(kind: .cpuTotal, unit: .percent, value: 30, timestamp: now.addingTimeInterval(0.2)),
        ])
        await store.flush()
        await store.flush()

        let restoredStore = HistoryStore(persistenceURL: url, persistenceSaveInterval: 3_600)
        let restoredBuckets = await restoredStore.buckets(
            for: .cpuTotal,
            unit: .percent,
            range: .oneHour,
            now: now,
        )

        #expect(restoredBuckets.count == 1)
        #expect(restoredBuckets.first?.count == 2)
        #expect(restoredBuckets.first?.avg == 20)
        #expect(restoredBuckets.first?.last == 30)
    }

    @Test
    func sqlitePersistsOlderSameBucketSamplesAcrossBatches() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeakmonHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let bucketStart = HistoryRange.oneHour.bucketStart(for: Date().addingTimeInterval(-10))
        let store = HistoryStore(persistenceURL: url, persistenceSaveInterval: 0)
        await store.ingest([
            MetricSample(kind: .cpuTotal, unit: .percent, value: 10, timestamp: bucketStart.addingTimeInterval(0.8)),
        ])
        await store.ingest([
            MetricSample(kind: .cpuTotal, unit: .percent, value: 30, timestamp: bucketStart.addingTimeInterval(0.2)),
        ])

        let restoredStore = HistoryStore(persistenceURL: url, persistenceSaveInterval: 3_600)
        let restoredBuckets = await restoredStore.buckets(
            for: .cpuTotal,
            unit: .percent,
            range: .oneHour,
            now: Date(),
        )

        #expect(restoredBuckets.count == 1)
        #expect(restoredBuckets.first?.count == 2)
        #expect(restoredBuckets.first?.max == 30)
        #expect(restoredBuckets.first?.last == 10)
        #expect(restoredBuckets.first?.lastSampleDate == bucketStart.addingTimeInterval(0.8))
    }

    @Test
    func legacyJSONMigratesIntoSQLite() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeakmonHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        let databaseURL = url.deletingPathExtension().appendingPathExtension("sqlite")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let bucketStart = HistoryRange.oneHour.bucketStart(for: Date().addingTimeInterval(-10))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyJSON = """
        {"version":2,"savedAt":\(Date().timeIntervalSinceReferenceDate),"ranges":[{"range":"1h","buckets":[{"kind":"cpu.total","unit":"percent","resolution":1,"startDate":\(bucketStart.timeIntervalSinceReferenceDate),"min":42,"avg":42,"max":42,"last":42,"count":1}]}]}
        """
        try Data(legacyJSON.utf8).write(to: url)

        let restoredStore = HistoryStore(persistenceURL: url, persistenceSaveInterval: 3_600)
        let restoredBuckets = await restoredStore.buckets(
            for: .cpuTotal,
            unit: .percent,
            range: .oneHour,
            now: Date(),
        )

        #expect(restoredBuckets.count == 1)
        #expect(restoredBuckets.first?.last == 42)
        #expect(FileManager.default.fileExists(atPath: databaseURL.path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func legacyJSONMergesIntoNonEmptySQLite() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeakmonHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let bucketStart = HistoryRange.oneHour.bucketStart(for: Date().addingTimeInterval(-10))
        let store = HistoryStore(persistenceURL: url, persistenceSaveInterval: 3_600)
        await store.ingest([
            MetricSample(kind: .cpuTotal, unit: .percent, value: 12, timestamp: bucketStart),
        ])
        await store.flush()

        let legacyJSON = """
        {"version":2,"savedAt":\(Date().timeIntervalSinceReferenceDate),"ranges":[{"range":"1h","buckets":[{"kind":"memory.pressure","unit":"percent","resolution":1,"startDate":\(bucketStart.timeIntervalSinceReferenceDate),"min":58,"avg":58,"max":58,"last":58,"count":1}]}]}
        """
        try Data(legacyJSON.utf8).write(to: url)

        let restoredStore = HistoryStore(persistenceURL: url, persistenceSaveInterval: 3_600)
        let cpuBuckets = await restoredStore.buckets(
            for: .cpuTotal,
            unit: .percent,
            range: .oneHour,
            now: Date(),
        )
        let memoryBuckets = await restoredStore.buckets(
            for: .memoryPressure,
            unit: .percent,
            range: .oneHour,
            now: Date(),
        )

        #expect(cpuBuckets.count == 1)
        #expect(memoryBuckets.count == 1)
        #expect(memoryBuckets.first?.last == 58)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func legacyIncrementLogMigratesAndSkipsDamagedLines() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeakmonHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        let logURL = url.appendingPathExtension("log")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let bucketStart = HistoryRange.oneHour.bucketStart(for: Date().addingTimeInterval(-10))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyLog = """
        {"version":1,"savedAt":\(Date().timeIntervalSinceReferenceDate),"records":[{"range":"1h","bucket":{"kind":"cpu.total","unit":"percent","resolution":1,"startDate":\(bucketStart.timeIntervalSinceReferenceDate),"min":33,"avg":33,"max":33,"last":33,"count":1}}]}
        {"version":
        """
        try Data(legacyLog.utf8).write(to: logURL)

        let restoredStore = HistoryStore(persistenceURL: url, persistenceSaveInterval: 3_600)
        let restoredBuckets = await restoredStore.buckets(
            for: .cpuTotal,
            unit: .percent,
            range: .oneHour,
            now: Date(),
        )

        #expect(restoredBuckets.count == 1)
        #expect(restoredBuckets.first?.last == 33)
        #expect(!FileManager.default.fileExists(atPath: logURL.path))
    }

    @Test
    func retainedKindsDropStalePersistedBuckets() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeakmonHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let now = Date()
        let store = HistoryStore(persistenceURL: url, persistenceSaveInterval: 3_600)
        await store.ingest([
            MetricSample(kind: .batteryLevel, unit: .percent, value: 80, timestamp: now),
            MetricSample(kind: .cpuTotal, unit: .percent, value: 12, timestamp: now),
        ])
        await store.flush()

        let restoredStore = HistoryStore(
            persistenceURL: url,
            persistenceSaveInterval: 3_600,
            retainedKinds: [.cpuTotal],
        )
        let batteryBuckets = await restoredStore.buckets(
            for: .batteryLevel,
            unit: .percent,
            range: .oneHour,
            now: now,
        )
        let cpuBuckets = await restoredStore.buckets(
            for: .cpuTotal,
            unit: .percent,
            range: .oneHour,
            now: now,
        )

        #expect(batteryBuckets.isEmpty)
        #expect(cpuBuckets.count == 1)
    }

    private func sqliteRowCount(at databaseURL: URL) -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database
        else {
            return -1
        }
        defer {
            sqlite3_close(database)
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM history_buckets;", -1, &statement, nil) == SQLITE_OK else {
            return -1
        }
        defer {
            sqlite3_finalize(statement)
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return -1
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func fileSize(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else {
            return 0
        }
        return size.int64Value
    }
}
