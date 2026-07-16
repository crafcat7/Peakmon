//
//  CollectorDemandGate.swift
//  Peakmon
//

import PeakmonCore

enum CollectorDemand: String, CaseIterable, Hashable, Sendable {
    case cpu
    case memory
    case disk
    case network
    case gpu
    case power
    case thermal
    case fan
    case battery
}

/// Lightweight demand switch for hardware-facing collectors.
actor CollectorDemandGate {
    private var active: Set<CollectorDemand> = []
    private var activationEpochs: [CollectorDemand: UInt64] = [:]
    private var latestGeneration: UInt64 = 0

    @discardableResult
    func setActive(_ demands: Set<CollectorDemand>, generation: UInt64) -> Bool {
        guard generation >= latestGeneration else { return false }
        latestGeneration = generation
        for demand in demands where !active.contains(demand) {
            activationEpochs[demand, default: 0] &+= 1
        }
        active = demands
        return true
    }

    func state(for demand: CollectorDemand) -> CollectorDemandState {
        CollectorDemandState(
            isActive: active.contains(demand),
            activationEpoch: activationEpochs[demand] ?? 0,
        )
    }
}

struct DemandGatedCollector<Wrapped: MetricCollector>: MetricCollector {
    let demand: CollectorDemand
    let collector: Wrapped
    let gate: CollectorDemandGate
    private let state = DemandGatedCollectorState()

    var identifier: String {
        "\(collector.identifier).demand.\(demand.rawValue)"
    }

    func collect() async throws -> [MetricSample] {
        let demandState = await gate.state(for: demand)
        guard demandState.isActive else { return [] }

        let reset: (@Sendable () async -> Void)?
        if let resettable = collector as? any ResettableMetricCollector {
            reset = { await resettable.reset() }
        } else {
            reset = nil
        }

        let task = await state.enqueueCollect(
            activationEpoch: demandState.activationEpoch,
            reset: reset,
            collect: { try await collector.collect() },
        )
        return try await task.value
    }
}

struct CollectorDemandState: Sendable {
    let isActive: Bool
    let activationEpoch: UInt64
}

private actor DemandGatedCollectorState {
    private var lastActiveEpoch: UInt64?
    private var tail: Task<Void, Never>?

    func enqueueCollect(
        activationEpoch: UInt64,
        reset: (@Sendable () async -> Void)?,
        collect: @escaping @Sendable () async throws -> [MetricSample],
    ) -> Task<[MetricSample], Error> {
        if let lastActiveEpoch, activationEpoch < lastActiveEpoch {
            return Task { [] }
        }

        let shouldReset = lastActiveEpoch.map { $0 != activationEpoch } ?? false
        lastActiveEpoch = activationEpoch

        let predecessor = tail
        let task = Task<[MetricSample], Error> {
            await predecessor?.value
            if shouldReset, let reset {
                await reset()
            }
            return try await collect()
        }
        tail = Task { _ = try? await task.value }
        return task
    }
}

extension MenuBarSegment {
    var collectorDemands: Set<CollectorDemand> {
        switch self {
        case .cpuPercent, .cpuGraph: [.cpu]
        case .gpuPercent, .gpuGraph: [.gpu]
        case .memoryPercent, .memoryGraph: [.memory]
        case .networkRate, .networkGraph: [.network]
        case .diskRate, .diskGraph: [.disk]
        case .powerWatts, .powerGraph: [.power]
        case .batteryPercent: [.battery]
        case .recentIssues: []
        }
    }
}

extension CardTintSlot {
    var popoverCollectorDemands: Set<CollectorDemand> {
        switch self {
        case .cpu: [.cpu, .thermal]
        case .gpu: [.gpu, .thermal]
        case .battery: [.battery]
        case .power: [.power, .fan, .battery]
        case .memory: [.memory]
        case .disk: [.disk]
        case .network: [.network]
        case .processes: []
        }
    }
}
