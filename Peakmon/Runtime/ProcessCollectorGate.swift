//
//  ProcessCollectorGate.swift
//  Peakmon
//

import PeakmonCollectors
import PeakmonCore

/// Gates expensive libproc walks on the Processes card's effective demand.
actor ProcessCollectorGate {
    nonisolated private let collector: ProcessCollector
    private var enabled = false
    private var didFlushAfterDisable = true
    private var latestGeneration: UInt64 = 0

    init(collector: ProcessCollector) {
        self.collector = collector
    }

    @discardableResult
    func setEnabled(_ value: Bool, generation: UInt64) async -> ProcessCollectorGateTransition {
        guard generation >= latestGeneration else { return .unchanged }
        latestGeneration = generation
        if value == enabled { return .unchanged }
        enabled = value
        didFlushAfterDisable = false
        if value {
            await collector.reset()
            return .enabled
        }
        return .disabled
    }

    func collect() async throws -> [ProcessSnapshot]? {
        let isEnabled = enabled
        let needsFlush = !didFlushAfterDisable
        if needsFlush { didFlushAfterDisable = true }

        if !isEnabled {
            return needsFlush ? [] : nil
        }
        return try await collector.collect()
    }
}

enum ProcessCollectorGateTransition: Sendable {
    case unchanged
    case enabled
    case disabled
}
