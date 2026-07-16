//
//  HistorySampleSink.swift
//  Peakmon
//

import Foundation
import PeakmonCollectors
import PeakmonCore

actor HistorySampleSink {
    private let recorder: HistoryRecorder
    private let issuesStore: HistoryIssuesStore
    private let drainDelay: Duration
    private let processSnapshotter = HistoryAnomalyProcessSnapshotter()
    private var pendingSamples: [MetricSample] = []
    private var attemptedProcessEventIDs: Set<UUID> = []
    private var drainTask: Task<Void, Never>?

    init(
        recorder: HistoryRecorder,
        issuesStore: HistoryIssuesStore,
        drainDelay: Duration = .milliseconds(250),
    ) {
        self.recorder = recorder
        self.issuesStore = issuesStore
        self.drainDelay = drainDelay
    }

    func enqueue(_ samples: [MetricSample]) {
        let historySamples = samples.filter { HistoryRecorder.shouldRecord($0) }
        guard !historySamples.isEmpty else { return }
        pendingSamples.append(contentsOf: historySamples)
        guard drainTask == nil else { return }
        let drainDelay = drainDelay
        drainTask = Task(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(for: drainDelay)
            } catch {}
            await self?.drain()
        }
    }

    func flush() async {
        if let drainTask {
            drainTask.cancel()
            await drainTask.value
        }
        let samples = pendingSamples
        pendingSamples.removeAll(keepingCapacity: true)
        if !samples.isEmpty {
            await ingest(samples)
        }
        await recorder.flush()
    }

    private func drain() async {
        while !Task.isCancelled {
            let samples = pendingSamples
            pendingSamples.removeAll(keepingCapacity: true)
            guard !samples.isEmpty else {
                drainTask = nil
                return
            }
            await ingest(samples)
        }
        drainTask = nil
    }

    private func ingest(_ samples: [MetricSample]) async {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        await recorder.ingestPrepared(ordered)
        guard let now = ordered.last?.timestamp else { return }
        await enrichAndPublish(at: now)
    }

    private func enrichAndPublish(at now: Date) async {
        var events = await recorder.anomalies(in: .oneHour, at: now)
        let currentIDs = Set(events.map(\.id))
        attemptedProcessEventIDs.formIntersection(currentIDs)

        let candidates = events.filter {
            $0.kind.capturesProcessContext
                && $0.processes.isEmpty
                && !attemptedProcessEventIDs.contains($0.id)
        }

        if !candidates.isEmpty {
            attemptedProcessEventIDs.formUnion(candidates.map(\.id))
            let snapshots = await processSnapshotter.capture()
            for event in candidates {
                let ranked = event.kind.rankedProcessContext(from: snapshots)
                _ = await recorder.attachProcesses(ranked, to: event.id)
            }
            events = await recorder.anomalies(in: .oneHour, at: now)
        }

        await issuesStore.update(events, at: now)
    }
}

private actor HistoryAnomalyProcessSnapshotter {
    private let collector = ProcessCollector()

    func capture() async -> [ProcessSnapshot] {
        await collector.reset()
        _ = try? await collector.collect()
        do {
            try await Task.sleep(for: .seconds(1))
        } catch {
            return []
        }
        return (try? await collector.collect()) ?? []
    }
}

private extension HistoryAnomalyKind {
    nonisolated var capturesProcessContext: Bool {
        switch self {
        case .cpuSustainedHigh, .memoryPressure, .memorySwapHigh, .powerSustainedHigh:
            true
        case .gpuSustainedHigh, .diskReadSustainedHigh, .diskWriteSustainedHigh,
             .networkInSustainedHigh, .networkOutSustainedHigh, .thermalCPUHigh, .thermalGPUHigh:
            false
        }
    }

    nonisolated func rankedProcessContext(from snapshots: [ProcessSnapshot]) -> [HistoryAnomalyProcessSnapshot] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let candidates = snapshots.filter { $0.pid != ownPID }
        let sorted: [ProcessSnapshot]
        switch self {
        case .memoryPressure, .memorySwapHigh:
            sorted = candidates.sorted { $0.memoryBytes > $1.memoryBytes }
        case .cpuSustainedHigh, .powerSustainedHigh:
            sorted = candidates.sorted { $0.cpuPercent > $1.cpuPercent }
        default:
            return []
        }

        return sorted.prefix(3).map {
            HistoryAnomalyProcessSnapshot(
                pid: $0.pid,
                name: $0.name,
                cpuPercent: $0.cpuPercent,
                memoryBytes: $0.memoryBytes,
            )
        }
    }
}
