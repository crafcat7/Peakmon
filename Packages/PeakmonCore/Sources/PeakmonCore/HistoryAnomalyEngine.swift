//
//  HistoryAnomalyEngine.swift
//  PeakmonCore
//
//  Stateful anomaly inference for diagnostic history samples.
//

import Foundation

private struct HistoryAnomalyRule {
    let kind: HistoryAnomalyKind
    let metricKind: MetricKind
    let unit: MetricUnit
    let minimumDuration: TimeInterval
    let minimumSamples: Int
    let lowThreshold: Double
    let mediumThreshold: Double
    let highThreshold: Double
    let recoveryThreshold: Double
    let reason: String

    func severity(for value: Double) -> HistoryAnomalySeverity? {
        if value >= highThreshold { return .high }
        if value >= mediumThreshold { return .medium }
        if value >= lowThreshold { return .low }
        return nil
    }

    func isRecovered(_ value: Double) -> Bool {
        value <= recoveryThreshold
    }
}

private struct ActiveAnomaly {
    let id: UUID
    let kind: HistoryAnomalyKind
    let metricKind: MetricKind
    let unit: MetricUnit
    let reason: String
    let startedAt: Date
    var endedAt: Date
    var severity: HistoryAnomalySeverity
    var peakValue: Double
    var lastSampleAt: Date
    var qualifyingSampleCount: Int
    var processes: [HistoryAnomalyProcessSnapshot]
}

struct HistoryAnomalyEngine {
    private let rules: [HistoryAnomalyRule] = [
        HistoryAnomalyRule(
            kind: .cpuSustainedHigh,
            metricKind: .cpuTotal,
            unit: .percent,
            minimumDuration: 5,
            minimumSamples: 2,
            lowThreshold: 80,
            mediumThreshold: 85,
            highThreshold: 95,
            recoveryThreshold: 70,
            reason: "CPU has been continuously high.",
        ),
        HistoryAnomalyRule(
            kind: .gpuSustainedHigh,
            metricKind: .gpuUtilization,
            unit: .percent,
            minimumDuration: 10,
            minimumSamples: 2,
            lowThreshold: 85,
            mediumThreshold: 92,
            highThreshold: 98,
            recoveryThreshold: 70,
            reason: "GPU utilization has stayed high.",
        ),
        HistoryAnomalyRule(
            kind: .memoryPressure,
            metricKind: .memoryPressureLevel,
            unit: .count,
            minimumDuration: 5,
            minimumSamples: 2,
            lowThreshold: 2,
            mediumThreshold: 4,
            highThreshold: 8,
            recoveryThreshold: 1.5,
            reason: "VM memory pressure is elevated.",
        ),
        HistoryAnomalyRule(
            kind: .memorySwapHigh,
            metricKind: .memorySwapUsed,
            unit: .bytes,
            minimumDuration: 10,
            minimumSamples: 2,
            lowThreshold: 512.0 * 1_024 * 1_024,
            mediumThreshold: 2.0 * 1_024 * 1_024 * 1_024,
            highThreshold: 4.0 * 1_024 * 1_024 * 1_024,
            recoveryThreshold: 256.0 * 1_024 * 1_024,
            reason: "Swap usage is elevated and can explain memory stalls.",
        ),
        HistoryAnomalyRule(
            kind: .powerSustainedHigh,
            metricKind: .powerSystem,
            unit: .watts,
            minimumDuration: 10,
            minimumSamples: 2,
            lowThreshold: 25,
            mediumThreshold: 40,
            highThreshold: 55,
            recoveryThreshold: 18,
            reason: "System power draw has stayed high.",
        ),
        HistoryAnomalyRule(
            kind: .diskReadSustainedHigh,
            metricKind: .diskReadRate,
            unit: .bytesPerSecond,
            minimumDuration: 10,
            minimumSamples: 2,
            lowThreshold: 25.0 * 1_024 * 1_024,
            mediumThreshold: 100.0 * 1_024 * 1_024,
            highThreshold: 300.0 * 1_024 * 1_024,
            recoveryThreshold: 10.0 * 1_024 * 1_024,
            reason: "Disk reads have stayed high.",
        ),
        HistoryAnomalyRule(
            kind: .diskWriteSustainedHigh,
            metricKind: .diskWriteRate,
            unit: .bytesPerSecond,
            minimumDuration: 10,
            minimumSamples: 2,
            lowThreshold: 25.0 * 1_024 * 1_024,
            mediumThreshold: 100.0 * 1_024 * 1_024,
            highThreshold: 300.0 * 1_024 * 1_024,
            recoveryThreshold: 10.0 * 1_024 * 1_024,
            reason: "Disk writes have stayed high.",
        ),
        HistoryAnomalyRule(
            kind: .networkInSustainedHigh,
            metricKind: .netInRate,
            unit: .bytesPerSecond,
            minimumDuration: 10,
            minimumSamples: 2,
            lowThreshold: 5.0 * 1_024 * 1_024,
            mediumThreshold: 25.0 * 1_024 * 1_024,
            highThreshold: 100.0 * 1_024 * 1_024,
            recoveryThreshold: 2.0 * 1_024 * 1_024,
            reason: "Network receive throughput has stayed high.",
        ),
        HistoryAnomalyRule(
            kind: .networkOutSustainedHigh,
            metricKind: .netOutRate,
            unit: .bytesPerSecond,
            minimumDuration: 10,
            minimumSamples: 2,
            lowThreshold: 5.0 * 1_024 * 1_024,
            mediumThreshold: 25.0 * 1_024 * 1_024,
            highThreshold: 100.0 * 1_024 * 1_024,
            recoveryThreshold: 2.0 * 1_024 * 1_024,
            reason: "Network send throughput has stayed high.",
        ),
        HistoryAnomalyRule(
            kind: .thermalCPUHigh,
            metricKind: .thermalCPU,
            unit: .celsius,
            minimumDuration: 5,
            minimumSamples: 2,
            lowThreshold: 85,
            mediumThreshold: 90,
            highThreshold: 100,
            recoveryThreshold: 80,
            reason: "CPU thermal temperature has been high.",
        ),
        HistoryAnomalyRule(
            kind: .thermalGPUHigh,
            metricKind: .thermalGPU,
            unit: .celsius,
            minimumDuration: 5,
            minimumSamples: 2,
            lowThreshold: 85,
            mediumThreshold: 90,
            highThreshold: 100,
            recoveryThreshold: 80,
            reason: "GPU thermal temperature has been high.",
        ),
    ]
    private var openEvents: [HistoryAnomalyKind: ActiveAnomaly] = [:]
    private var events: [HistoryAnomalyEvent] = []
    private let mergeTolerance: TimeInterval = 30
    private let eventRetention: TimeInterval = HistoryRange.twentyFourHours.duration + 30

    mutating func ingest(_ orderedSamples: [MetricSample]) {
        guard let now = orderedSamples.last?.timestamp else { return }

        for sample in orderedSamples {
            for rule in rules where sample.kind == rule.metricKind && sample.unit == rule.unit {
                if let severity = rule.severity(for: sample.value) {
                    if var active = openEvents[rule.kind] {
                        active.endedAt = sample.timestamp
                        active.peakValue = max(active.peakValue, sample.value)
                        if severity.rawValue > active.severity.rawValue {
                            active.severity = severity
                        }
                        active.lastSampleAt = sample.timestamp
                        active.qualifyingSampleCount += 1
                        openEvents[rule.kind] = active
                    } else {
                        openEvents[rule.kind] = ActiveAnomaly(
                            id: UUID(),
                            kind: rule.kind,
                            metricKind: sample.kind,
                            unit: sample.unit,
                            reason: rule.reason,
                            startedAt: sample.timestamp,
                            endedAt: sample.timestamp,
                            severity: severity,
                            peakValue: sample.value,
                            lastSampleAt: sample.timestamp,
                            qualifyingSampleCount: 1,
                            processes: [],
                        )
                    }
                } else if let active = openEvents[rule.kind], active.lastSampleAt <= sample.timestamp {
                    if rule.isRecovered(sample.value) {
                        finalize(rule: rule, active: active)
                        openEvents[rule.kind] = nil
                    } else {
                        var coolingActive = active
                        coolingActive.lastSampleAt = sample.timestamp
                        openEvents[rule.kind] = coolingActive
                    }
                }
            }
        }

        for rule in rules {
            guard let active = openEvents[rule.kind] else { continue }
            if now.timeIntervalSince(active.lastSampleAt) >= max(30, rule.minimumDuration) {
                finalize(rule: rule, active: active)
                openEvents[rule.kind] = nil
            }
        }
        pruneEvents(at: now)
    }

    mutating func events(in range: HistoryRange, at now: Date) -> [HistoryAnomalyEvent] {
        pruneEvents(at: now)
        let cutoff = now.addingTimeInterval(-range.duration)
        let activeEvents = rules.compactMap { rule -> HistoryAnomalyEvent? in
            guard let active = openEvents[rule.kind] else { return nil }
            let endDate = active.lastSampleAt > active.endedAt ? active.endedAt : now
            guard isReportable(rule: rule, active: active, endDate: endDate) else { return nil }
            return event(rule: rule, active: active, endDate: endDate)
        }

        return (events + activeEvents)
            .filter { $0.endDate >= cutoff }
            .filter { $0.startDate <= now }
            .sorted { $0.startDate < $1.startDate }
    }

    mutating func reset() {
        events.removeAll(keepingCapacity: true)
        openEvents.removeAll(keepingCapacity: true)
    }

    @discardableResult
    mutating func attachProcesses(
        _ processes: [HistoryAnomalyProcessSnapshot],
        to eventID: UUID,
    ) -> Bool {
        guard !processes.isEmpty else { return false }

        if let kind = openEvents.first(where: { $0.value.id == eventID })?.key,
           var active = openEvents[kind]
        {
            guard active.processes.isEmpty else { return false }
            active.processes = processes
            openEvents[kind] = active
            return true
        }

        guard let index = events.firstIndex(where: { $0.id == eventID }) else { return false }
        let event = events[index]
        guard event.processes.isEmpty else { return false }
        events[index] = HistoryAnomalyEvent(
            id: event.id,
            kind: event.kind,
            metricKind: event.metricKind,
            unit: event.unit,
            startDate: event.startDate,
            endDate: event.endDate,
            severity: event.severity,
            reason: event.reason,
            peakValue: event.peakValue,
            processes: processes,
        )
        return true
    }

    private mutating func finalize(rule: HistoryAnomalyRule, active: ActiveAnomaly) {
        guard isReportable(rule: rule, active: active, endDate: active.endedAt) else { return }
        mergeOrAppend(event(rule: rule, active: active, endDate: active.endedAt))
    }

    private func isReportable(
        rule: HistoryAnomalyRule,
        active: ActiveAnomaly,
        endDate: Date,
    ) -> Bool {
        endDate.timeIntervalSince(active.startedAt) >= rule.minimumDuration
            && active.qualifyingSampleCount >= rule.minimumSamples
    }

    private func event(
        rule _: HistoryAnomalyRule,
        active: ActiveAnomaly,
        endDate: Date,
    ) -> HistoryAnomalyEvent {
        HistoryAnomalyEvent(
            id: active.id,
            kind: active.kind,
            metricKind: active.metricKind,
            unit: active.unit,
            startDate: active.startedAt,
            endDate: max(active.endedAt, endDate),
            severity: active.severity,
            reason: active.reason,
            peakValue: active.peakValue,
            processes: active.processes,
        )
    }

    private mutating func mergeOrAppend(_ next: HistoryAnomalyEvent) {
        guard !events.isEmpty else {
            events.append(next)
            return
        }

        if let index = events.indices.reversed().first(where: { shouldMerge(events[$0], with: next) }),
           let merged = events[index].merged(with: next) {
            events[index] = merged
        } else {
            events.append(next)
        }
    }

    private func shouldMerge(_ event: HistoryAnomalyEvent, with next: HistoryAnomalyEvent) -> Bool {
        guard event.kind == next.kind,
              event.metricKind == next.metricKind,
              event.unit == next.unit else { return false }
        if event.endDate < next.startDate {
            return next.startDate.timeIntervalSince(event.endDate) <= mergeTolerance
        }
        if next.endDate < event.startDate {
            return event.startDate.timeIntervalSince(next.endDate) <= mergeTolerance
        }
        return true
    }

    private mutating func pruneEvents(at now: Date) {
        let cutoff = now.addingTimeInterval(-eventRetention)
        events.removeAll { $0.endDate < cutoff }
    }
}
