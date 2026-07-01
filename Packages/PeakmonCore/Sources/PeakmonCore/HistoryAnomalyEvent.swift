//
//  HistoryAnomalyEvent.swift
//  PeakmonCore
//
//  Lightweight anomaly-event model for history consumers.
//

import Foundation

public enum HistoryAnomalyKind: String, CaseIterable, Codable, Hashable, Sendable {
    case cpuSustainedHigh
    case gpuSustainedHigh
    case memoryPressure
    case memorySwapHigh
    case powerSustainedHigh
    case diskReadSustainedHigh
    case diskWriteSustainedHigh
    case networkInSustainedHigh
    case networkOutSustainedHigh
    case thermalCPUHigh
    case thermalGPUHigh
}

public enum HistoryAnomalySeverity: Int, Comparable, Codable, Hashable, Sendable {
    case low = 1
    case medium = 2
    case high = 3

    public static func < (lhs: HistoryAnomalySeverity, rhs: HistoryAnomalySeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Single anomaly interval emitted by `HistoryRecorder`.
///
/// Kept intentionally small and copy-safe so it can be forwarded to
/// UI with minimal serialization cost and no persistence dependency.
public struct HistoryAnomalyEvent: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let kind: HistoryAnomalyKind
    public let metricKind: MetricKind
    public let unit: MetricUnit

    /// Start of the detected anomaly interval.
    public let startDate: Date

    /// End of the detected anomaly interval.
    public let endDate: Date

    /// Event severity from a stable scale that can be mapped directly.
    public let severity: HistoryAnomalySeverity

    /// Human-readable explanation used by UI tooltips / rows.
    public let reason: String

    /// Peak sample observed inside the anomaly interval.
    public let peakValue: Double

    /// Merge `other` into this event if adjacent / overlapping, otherwise
    /// return `nil`.
    public func merged(with other: HistoryAnomalyEvent) -> HistoryAnomalyEvent? {
        guard other.kind == kind,
              other.metricKind == metricKind,
              other.unit == unit else { return nil }
        return HistoryAnomalyEvent(
            id: id,
            kind: kind,
            metricKind: metricKind,
            unit: unit,
            startDate: min(startDate, other.startDate),
            endDate: max(endDate, other.endDate),
            severity: max(severity, other.severity),
            reason: reason,
            peakValue: max(peakValue, other.peakValue),
        )
    }
}
