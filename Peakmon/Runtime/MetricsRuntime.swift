//
//  MetricsRuntime.swift
//  Peakmon
//

import Foundation
import Observation
import PeakmonCollectors
import PeakmonCore

/// Holds the long-running `MetricsScheduler` so SwiftUI can keep it
/// alive across re-renders.
private struct SchedulerCadence: Equatable {
    let fast: Duration
    let medium: Duration
    let slow: Duration
}

private enum PowerAwareCadencePolicy {
    case normal
    case onBattery
    case lowPower
}

@MainActor
@Observable
final class MetricsRuntime {
    private(set) var started = false
    private var fastScheduler: MetricsScheduler?
    private var mediumScheduler: MetricsScheduler?
    private var slowScheduler: MetricsScheduler?
    private var processTask: Task<Void, Never>?
    private var powerPolicyTask: Task<Void, Never>?
    private var metricsStore: MetricsStore?
    private var processesStore: ProcessesStore?
    private var processGateGeneration: UInt64 = 0
    private var requestedSamplingIntervalSeconds = 1.0
    private var appliedCadence: SchedulerCadence?
    private var menuBarSegments = MenuBarComposition.defaultSegments
    private var popoverConfiguredSlots: [CardTintSlot] = []
    private var activeCollectorDemand: Set<CollectorDemand> = []
    private var collectorDemandGeneration: UInt64 = 0
    private let collectorDemandGate = CollectorDemandGate()
    private static let foregroundHistoryCollectorDemands: Set<CollectorDemand> = [
        .cpu,
        .memory,
        .disk,
        .network,
        .gpu,
        .power,
        .thermal,
        .fan,
        .battery,
    ]
    private static let backgroundHistoryCollectorDemands: Set<CollectorDemand> = [
        .cpu,
        .memory,
        .disk,
        .network,
        .gpu,
        .power,
        .thermal,
        .fan,
        .battery,
    ]

    /// True while the popover dashboard is actually on-screen. When
    /// false and the main dashboard is also hidden, the runtime keeps
    /// the menu-bar label fresh at a lower cadence instead of polling
    /// every collector at full dashboard speed.
    var popoverVisible = false {
        didSet {
            updateCollectorDemand()
        }
    }

    /// True while the main dashboard surface is worth painting. This
    /// tracks visibility, not merely whether the Window scene exists.
    var mainDashboardVisible = false {
        didSet {
            updateCollectorDemand()
        }
    }

    /// True while the history diagnostics surface is visible. History
    /// recording runs at low cadence in the background; making the
    /// surface visible raises those host collectors to foreground
    /// diagnostic cadence without requiring the process collector.
    var historyVisible = false {
        didSet {
            updateCollectorDemand()
        }
    }

    /// User preference for the heavy Processes card. The runtime only
    /// walks libproc when this is true *and* a visible surface is
    /// currently reading process data.
    var processesEnabled = false {
        didSet {
            updateProcessGate()
        }
    }

    /// True while the menu-bar popover is visible and includes the
    /// Processes card.
    var popoverNeedsProcesses = false {
        didSet {
            updateProcessGate()
        }
    }

    /// True while the main dashboard window is visible and includes
    /// the full-width Processes panel.
    var mainDashboardNeedsProcesses = false {
        didSet {
            updateProcessGate()
        }
    }

    /// Cadence at which the process collector polls libproc, in
    /// seconds. Kept slower than the host-metric scheduler because
    /// walking ~500 PIDs is ~50x more expensive than a single
    /// `host_statistics64` call. 2 s matches Activity Monitor's
    /// default refresh and is plenty for trend spotting.
    private static let processInterval: Duration = .seconds(2)
    private let processCollector = ProcessCollectorGate(collector: ProcessCollector())

    func updateMenuBarSegments(_ segments: [MenuBarSegment]) {
        guard segments != menuBarSegments else { return }
        menuBarSegments = segments
        updateCollectorDemand()
    }

    func updatePopoverConfiguredSlots(_ slots: [CardTintSlot]) {
        guard slots != popoverConfiguredSlots else { return }
        popoverConfiguredSlots = slots
        updateCollectorDemand()
    }

    func start(
        store: MetricsStore,
        historySampleSink: HistorySampleSink,
        processesStore: ProcessesStore,
        interval: Double,
    ) {
        guard !started else { return }
        started = true
        metricsStore = store
        self.processesStore = processesStore
        requestedSamplingIntervalSeconds = interval
        let cadence = effectiveCadence()
        let historySink: @Sendable ([MetricSample]) async -> Void = { samples in
            await historySampleSink.enqueue(samples)
        }
        let fastScheduler = MetricsScheduler(
            store: store,
            collectors: [
                DemandGatedCollector(demand: .cpu, collector: CPUCollector(), gate: collectorDemandGate),
                DemandGatedCollector(demand: .memory, collector: MemoryCollector(), gate: collectorDemandGate),
                DemandGatedCollector(demand: .disk, collector: DiskCollector(), gate: collectorDemandGate),
                DemandGatedCollector(demand: .network, collector: NetworkCollector(), gate: collectorDemandGate),
            ],
            interval: cadence.fast,
            sampleSink: historySink,
        )
        let mediumScheduler = MetricsScheduler(
            store: store,
            collectors: [
                DemandGatedCollector(demand: .gpu, collector: GPUCollector(), gate: collectorDemandGate),
                DemandGatedCollector(demand: .power, collector: PowerCollector(), gate: collectorDemandGate),
                DemandGatedCollector(demand: .power, collector: SystemPowerCollector(), gate: collectorDemandGate),
                DemandGatedCollector(demand: .thermal, collector: ThermalCollector(), gate: collectorDemandGate),
                DemandGatedCollector(demand: .fan, collector: FanCollector(), gate: collectorDemandGate),
            ],
            interval: cadence.medium,
            sampleSink: historySink,
        )
        let slowScheduler = MetricsScheduler(
            store: store,
            collectors: [
                DemandGatedCollector(demand: .battery, collector: BatteryCollector(), gate: collectorDemandGate),
            ],
            interval: cadence.slow,
            sampleSink: historySink,
        )
        self.fastScheduler = fastScheduler
        self.mediumScheduler = mediumScheduler
        self.slowScheduler = slowScheduler
        appliedCadence = cadence
        Task { await fastScheduler.start() }
        Task { await mediumScheduler.start() }
        Task { await slowScheduler.start() }
        updateCollectorDemand()
        spawnProcessLoop(processesStore: processesStore)
        spawnPowerPolicyLoop()
    }

    /// Pushes a new sampling cadence into the running scheduler.
    /// Called from the SwiftUI scene whenever the user changes the
    /// `samplingIntervalSeconds` AppStorage value.
    func updateInterval(seconds: Double) {
        requestedSamplingIntervalSeconds = seconds
        updateCollectorDemand()
    }

    private func updateCollectorDemand() {
        let demands = effectiveCollectorDemand()
        let demandChanged = demands != activeCollectorDemand
        if demandChanged {
            activeCollectorDemand = demands
        }

        let cadence = effectiveCadence()
        let cadenceChanged = cadence != appliedCadence
        guard demandChanged || cadenceChanged else { return }
        let gate = collectorDemandGate
        collectorDemandGeneration &+= 1
        let generation = collectorDemandGeneration
        appliedCadence = cadence

        Task {
            if demandChanged {
                let didApplyGate = await gate.setActive(demands, generation: generation)
                guard didApplyGate else { return }
            }
            guard isCurrentCollectorDemandGeneration(generation) else { return }
            await updateSchedulers(to: cadence)
        }
    }

    private func isCurrentCollectorDemandGeneration(_ generation: UInt64) -> Bool {
        generation == collectorDemandGeneration
    }

    private func updateSchedulers(to cadence: SchedulerCadence) async {
        if let fastScheduler {
            await fastScheduler.updateInterval(cadence.fast)
        }
        if let mediumScheduler {
            await mediumScheduler.updateInterval(cadence.medium)
        }
        if let slowScheduler {
            await slowScheduler.updateInterval(cadence.slow)
        }
    }

    private func effectiveCollectorDemand() -> Set<CollectorDemand> {
        var demands = Set<CollectorDemand>()

        // Keep a low-frequency baseline for every History metric before
        // the user opens the panel. Showing History raises the same
        // collectors to foreground cadence instead of cold-starting
        // sparse series such as GPU, thermal, or fans.
        demands.formUnion(
            historyVisible
                ? Self.foregroundHistoryCollectorDemands
                : Self.backgroundHistoryCollectorDemands,
        )

        for segment in menuBarSegments {
            demands.formUnion(segment.collectorDemands)
        }

        if popoverVisible {
            for slot in popoverConfiguredSlots {
                demands.formUnion(slot.popoverCollectorDemands)
            }
        }

        if mainDashboardVisible {
            // The main dashboard currently renders CPU, Memory, GPU,
            // Power, Disk, and Network unconditionally. CPU/GPU need
            // thermal samples; GPU and Power need IOReport power;
            // Power folds in Battery state.
            demands.formUnion([.cpu, .memory, .disk, .network, .gpu, .power, .thermal, .battery])
        }

        return demands
    }

    private func effectiveCadence() -> SchedulerCadence {
        let detailedSurfaceVisible = popoverVisible || mainDashboardVisible || historyVisible
        let hasFastDemand = !activeCollectorDemand.isDisjoint(with: [.cpu, .memory, .disk, .network])
        let hasMediumDemand = !activeCollectorDemand.isDisjoint(with: [.gpu, .power, .thermal, .fan])
        let hasSlowDemand = activeCollectorDemand.contains(.battery)
        let backgroundPolicy = detailedSurfaceVisible ? .normal : powerAwareCadencePolicy()
        let backgroundFastMinimum: Double
        let backgroundMediumMinimum: Double
        let backgroundSlowMinimum: Double
        switch backgroundPolicy {
        case .normal:
            backgroundFastMinimum = 5
            backgroundMediumMinimum = hasMediumDemand ? 30 : 60
            backgroundSlowMinimum = hasSlowDemand ? 60 : 300
        case .onBattery:
            backgroundFastMinimum = 10
            backgroundMediumMinimum = hasMediumDemand ? 60 : 120
            backgroundSlowMinimum = hasSlowDemand ? 120 : 300
        case .lowPower:
            backgroundFastMinimum = 15
            backgroundMediumMinimum = hasMediumDemand ? 120 : 300
            backgroundSlowMinimum = 300
        }
        let fastMinimum = hasFastDemand
            ? (detailedSurfaceVisible ? 0.05 : backgroundFastMinimum)
            : 60
        return SchedulerCadence(
            fast: Self.duration(
                seconds: requestedSamplingIntervalSeconds,
                minimum: fastMinimum,
            ),
            medium: Self.duration(
                seconds: requestedSamplingIntervalSeconds,
                minimum: detailedSurfaceVisible ? (hasMediumDemand ? 2 : 60) : backgroundMediumMinimum,
            ),
            slow: Self.duration(
                seconds: requestedSamplingIntervalSeconds,
                minimum: detailedSurfaceVisible ? (hasSlowDemand ? 10 : 300) : backgroundSlowMinimum,
            ),
        )
    }

    private func powerAwareCadencePolicy() -> PowerAwareCadencePolicy {
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return .lowPower
        }

        guard
            let metricsStore,
            let sourceSample = metricsStore.latest(for: .batteryPowerSource)
        else {
            return .normal
        }

        let source = BatteryPowerSource(metricValue: sourceSample.value)
        guard source == .onBattery else { return .normal }

        let level = metricsStore.latest(for: .batteryLevel)?.value
        if let level, level <= 20 {
            return .lowPower
        }
        return .onBattery
    }

    private static func duration(seconds: Double, minimum: Double = 0.05) -> Duration {
        // `Duration.seconds(_:)` only accepts integers when used with
        // a `Double` literal needs `.milliseconds` to keep sub-second
        // precision (e.g. 0.5 s -> 500 ms).
        let clamped = max(minimum, seconds)
        let millis = Int((clamped * 1000).rounded())
        return .milliseconds(max(50, millis))
    }

    private func updateProcessGate() {
        let shouldCollect = processesEnabled
            && (popoverNeedsProcesses || mainDashboardNeedsProcesses)
        processGateGeneration &+= 1
        let generation = processGateGeneration
        let gate = processCollector
        let processesStore = processesStore
        Task {
            let transition = await gate.setEnabled(shouldCollect, generation: generation)
            switch transition {
            case .enabled:
                break
            case .disabled:
                await MainActor.run {
                    processesStore?.clear()
                }
                return
            case .unchanged:
                return
            }

            guard let processesStore else { return }

            // Seed a fresh baseline immediately, then publish the
            // first real diff one second later instead of waiting for
            // the detached 2 s polling loop to line up twice.
            _ = try? await gate.collect()
            try? await Task.sleep(for: .seconds(1))
            if let snapshots = try? await gate.collect() {
                await MainActor.run {
                    processesStore.ingest(snapshots)
                }
            }
        }
    }

    /// Long-running task that polls `ProcessCollector` on the slower
    /// fixed cadence. Cancellation happens implicitly when the
    /// runtime is deallocated; the task observes `Task.isCancelled`
    /// and returns cleanly.
    private func spawnProcessLoop(processesStore: ProcessesStore) {
        let gate = processCollector
        processTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                do {
                    if let snapshots = try await gate.collect() {
                        await MainActor.run {
                            processesStore.ingest(snapshots)
                        }
                    }
                } catch {
                    // Process enumeration is best-effort; failures are
                    // dropped silently so a single bad tick doesn't
                    // tear the loop down.
                }
                do {
                    try await Task.sleep(for: Self.processInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func spawnPowerPolicyLoop() {
        powerPolicyTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
                self?.updateCollectorDemand()
            }
        }
    }
}
