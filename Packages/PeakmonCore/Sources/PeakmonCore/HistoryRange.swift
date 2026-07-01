//
//  HistoryRange.swift
//  PeakmonCore
//
//  Defines bounded query windows for local historical aggregation.
//

import Foundation

/// Bounded retention windows used by the in-memory history recorder.
public enum HistoryRange: String, Codable, CaseIterable, Sendable, Hashable {
    case oneHour = "1h"
    case sixHours = "6h"
    case twentyFourHours = "24h"

    /// Longest retention horizon across all supported history ranges.
    public static var maximumDuration: TimeInterval {
        allCases.map(\.duration).max() ?? 24 * 60 * 60
    }

    /// How long each range keeps samples.
    public var duration: TimeInterval {
        switch self {
        case .oneHour:
            60 * 60
        case .sixHours:
            6 * 60 * 60
        case .twentyFourHours:
            24 * 60 * 60
        }
    }

    /// Aggregation bucket width for this range.
    ///
    /// The 1-hour window keeps the finest granularity (1 s),
    /// while longer windows store pre-aggregated buckets so we do
    /// not retain raw data for multi-hour history.
    public var bucketInterval: TimeInterval {
        switch self {
        case .oneHour:
            1
        case .sixHours:
            10
        case .twentyFourHours:
            60
        }
    }

    /// Human readable label used by UI consumers when needed.
    public var displayName: String {
        switch self {
        case .oneHour:
            "1h"
        case .sixHours:
            "6h"
        case .twentyFourHours:
            "24h"
        }
    }

    /// Pre-compute a bucket boundary for a sample timestamp.
    public func bucketStart(for date: Date) -> Date {
        let origin = date.timeIntervalSinceReferenceDate
        let aligned = floor(origin / bucketInterval) * bucketInterval
        return Date(timeIntervalSinceReferenceDate: aligned)
    }
}
