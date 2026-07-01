//
//  MetricHistoryBucket.swift
//  PeakmonCore
//
//  Aggregated metric value bucket.
//

import Foundation

/// Aggregated statistics for one metric stream over one bucket window.
public struct MetricHistoryBucket: Codable, Hashable, Identifiable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case unit
        case resolution
        case startDate
        case min
        case avg
        case max
        case last
        case lastSampleDate
        case count
    }

    public var id: String {
        "\(kind.rawValue)|\(unit.rawValue)|\(Int(resolution))|\(startDate.timeIntervalSinceReferenceDate)"
    }

    /// Kind that generated the bucket.
    public let kind: MetricKind

    /// Unit for the aggregated value.
    public let unit: MetricUnit

    /// Bucket width in seconds.
    public let resolution: TimeInterval

    /// Bucket start timestamp (inclusive).
    public let startDate: Date

    /// Minimum value seen in the bucket.
    public let min: Double

    /// Mean value over all bucket samples.
    public let avg: Double

    /// Maximum value seen in the bucket.
    public let max: Double

    /// Last value (most recent by sample timestamp) in bucket.
    public let last: Double

    /// Timestamp of the sample represented by `last`.
    public let lastSampleDate: Date

    /// Number of samples contributing to this bucket.
    public let count: Int

    public init(
        kind: MetricKind,
        unit: MetricUnit,
        resolution: TimeInterval,
        startDate: Date,
        min: Double,
        avg: Double,
        max: Double,
        last: Double,
        lastSampleDate: Date,
        count: Int,
    ) {
        self.kind = kind
        self.unit = unit
        self.resolution = resolution
        self.startDate = startDate
        self.min = min
        self.avg = avg
        self.max = max
        self.last = last
        self.lastSampleDate = lastSampleDate
        self.count = count
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(MetricKind.self, forKey: .kind)
        unit = try container.decode(MetricUnit.self, forKey: .unit)
        resolution = try container.decode(TimeInterval.self, forKey: .resolution)
        startDate = try container.decode(Date.self, forKey: .startDate)
        min = try container.decode(Double.self, forKey: .min)
        avg = try container.decode(Double.self, forKey: .avg)
        max = try container.decode(Double.self, forKey: .max)
        last = try container.decode(Double.self, forKey: .last)
        lastSampleDate = try container.decodeIfPresent(Date.self, forKey: .lastSampleDate) ?? startDate
        count = try container.decode(Int.self, forKey: .count)
    }
}
