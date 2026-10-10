import Foundation

/// A process instance, rather than a PID that can be reused after exit.
public struct FrameRateProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64

    public init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }

    public var startedAt: Date {
        Date(timeIntervalSince1970: Double(startSeconds) + Double(startMicroseconds) / 1_000_000)
    }
}

public enum FrameRateScope: String, CaseIterable, Sendable {
    case desktop
    case application
}

/// One fixed presentation source. Sources are never summed into an app FPS.
public struct FrameRateSource: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let scope: FrameRateScope
    public let processIdentity: FrameRateProcessIdentity?
    public let layerID: String?

    public init(
        id: String,
        name: String,
        scope: FrameRateScope,
        processIdentity: FrameRateProcessIdentity? = nil,
        layerID: String? = nil,
    ) {
        self.id = id
        self.name = name
        self.scope = scope
        self.processIdentity = processIdentity
        self.layerID = layerID
    }
}

/// A recorded interval; polling time must not replace its original timestamps.
public struct FrameRateReading: Equatable, Sendable, Identifiable {
    public let source: FrameRateSource
    public let intervalStart: Date
    public let intervalEnd: Date
    public let framesPerSecond: Double
    public let frameIntervalMilliseconds: Double?

    public init(
        source: FrameRateSource,
        intervalStart: Date,
        intervalEnd: Date,
        framesPerSecond: Double,
        frameIntervalMilliseconds: Double? = nil,
    ) {
        self.source = source
        self.intervalStart = intervalStart
        self.intervalEnd = intervalEnd
        self.framesPerSecond = framesPerSecond
        self.frameIntervalMilliseconds = frameIntervalMilliseconds
    }

    public var id: String { "\(source.id):\(intervalStart.timeIntervalSince1970):\(intervalEnd.timeIntervalSince1970)" }
    public var duration: TimeInterval { intervalEnd.timeIntervalSince(intervalStart) }

    public var isValid: Bool {
        intervalStart.timeIntervalSince1970.isFinite
            && intervalEnd.timeIntervalSince1970.isFinite
            && duration > 0
            && framesPerSecond.isFinite
            && framesPerSecond >= 0
            && (frameIntervalMilliseconds.map { $0.isFinite && $0 > 0 } ?? true)
    }
}

public struct FrameRateMarker: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date

    public init(timestamp: Date) {
        id = UUID()
        self.timestamp = timestamp
    }
}

/// Bounded, source-specific results for one user-initiated observation.
public struct FrameRateObservationSession: Sendable {
    public static let observationDuration: TimeInterval = 60
    public private(set) var source: FrameRateSource?
    public private(set) var startedAt: Date?
    public private(set) var endedAt: Date?
    public private(set) var readings: [FrameRateReading] = []
    public private(set) var markers: [FrameRateMarker] = []
    private static let readingLimit = 180

    public init() {}

    public mutating func begin(source: FrameRateSource, at date: Date = .now) {
        self.source = source
        startedAt = date
        endedAt = nil
        readings.removeAll(keepingCapacity: true)
        markers.removeAll(keepingCapacity: true)
    }

    public mutating func ingest(_ batch: [FrameRateReading]) {
        guard let source, let startedAt, endedAt == nil else { return }
        let existing = Set(readings.map(\.id))
        let accepted = batch.filter {
            $0.source == source && $0.isValid
                && $0.intervalStart >= startedAt
                && $0.intervalEnd <= startedAt.addingTimeInterval(Self.observationDuration)
                && !existing.contains($0.id)
        }
        var byID = Dictionary(uniqueKeysWithValues: readings.map { ($0.id, $0) })
        for reading in accepted { byID[reading.id] = reading }
        readings = byID.values.sorted { $0.intervalEnd < $1.intervalEnd }
        if readings.count > Self.readingLimit { readings.removeFirst(readings.count - Self.readingLimit) }
    }

    public mutating func mark(at date: Date = .now) {
        guard let startedAt, endedAt == nil, date >= startedAt,
              date <= startedAt.addingTimeInterval(Self.observationDuration), markers.count < 60 else { return }
        markers.append(FrameRateMarker(timestamp: date))
    }

    public mutating func finish(at date: Date = .now) {
        guard let startedAt, endedAt == nil else { return }
        endedAt = min(startedAt.addingTimeInterval(Self.observationDuration), max(startedAt, date))
        if let endedAt {
            readings.removeAll { $0.intervalEnd > endedAt }
            markers.removeAll { $0.timestamp > endedAt }
        }
    }
}
