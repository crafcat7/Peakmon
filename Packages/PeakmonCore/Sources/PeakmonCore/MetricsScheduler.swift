//
//  MetricsScheduler.swift
//  PeakmonCore
//
//  Drives a set of `MetricCollector`s at a fixed cadence using
//  Swift Concurrency. No `Timer`, no `Combine` — a single long-running
//  `Task` per scheduler instance with `Task.sleep(for:)` between ticks.
//

import Foundation

/// Coordinates periodic polling of collectors and feeds results into
/// `MetricsStore`.
///
/// The scheduler is an actor so `start()` / `stop()` can be called from
/// any context; the actual polling loop runs on a detached background
/// task and hops onto MainActor only to mutate the store.
public actor MetricsScheduler {
    private let store: MetricsStore
    private let collectors: [any MetricCollector]
    private var interval: Duration
    private var task: Task<Void, Never>?

    public init(
        store: MetricsStore,
        collectors: [any MetricCollector],
        interval: Duration = .seconds(1),
    ) {
        self.store = store
        self.collectors = collectors
        self.interval = interval
    }

    /// Begin polling. No-op if already running.
    public func start() {
        guard task == nil else { return }
        spawnLoop()
    }

    /// Cancel the polling loop. Safe to call multiple times.
    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Swap the polling cadence on the fly. If the scheduler is
    /// already running, the active loop is cancelled and a fresh
    /// one starts with the new interval; otherwise the value is
    /// stored for the next `start()` call.
    public func updateInterval(_ newValue: Duration) {
        guard newValue != interval else { return }
        interval = newValue
        guard task != nil else { return }
        task?.cancel()
        task = nil
        spawnLoop()
    }

    private func spawnLoop() {
        let collectors = collectors
        let interval = interval
        let store = store
        task = Task.detached(priority: .utility) {
            await Self.runLoop(
                collectors: collectors,
                interval: interval,
                store: store,
            )
        }
    }

    private static func runLoop(
        collectors: [any MetricCollector],
        interval: Duration,
        store: MetricsStore,
    ) async {
        while !Task.isCancelled {
            await withTaskGroup(of: [MetricSample].self) { group in
                for collector in collectors {
                    group.addTask {
                        (try? await collector.collect()) ?? []
                    }
                }
                var batch: [MetricSample] = []
                for await samples in group {
                    batch.append(contentsOf: samples)
                }
                if !batch.isEmpty {
                    await store.ingest(batch)
                }
            }
            do {
                try await Task.sleep(for: interval)
            } catch {
                return // cancelled
            }
        }
    }
}
