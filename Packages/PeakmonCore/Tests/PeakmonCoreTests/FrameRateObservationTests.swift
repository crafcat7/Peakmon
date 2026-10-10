import Foundation
import Testing
@testable import PeakmonCore

@Suite("Frame-rate observation sessions")
struct FrameRateObservationTests {
    let start = Date(timeIntervalSince1970: 1_000)
    let source = FrameRateSource(id: "desktop.DCP", name: "Built-in display", scope: .desktop)

    func reading(_ offset: Double, fps: Double = 60, source: FrameRateSource? = nil) -> FrameRateReading {
        FrameRateReading(
            source: source ?? self.source,
            intervalStart: start.addingTimeInterval(offset),
            intervalEnd: start.addingTimeInterval(offset + 1),
            framesPerSecond: fps,
        )
    }

    @Test func acceptsMeasuredZeroButRejectsInvalidAndPreSessionWindows() {
        var session = FrameRateObservationSession()
        session.begin(source: source, at: start)
        session.ingest([reading(-1), reading(0, fps: 0), reading(1, fps: -.infinity), reading(2, fps: -1)])
        #expect(session.readings.count == 1)
        #expect(session.readings.first?.framesPerSecond == 0)
        #expect(session.readings.first?.duration == 1)
    }

    @Test func fixesSourceAndRejectsOtherProcessInstances() {
        let first = FrameRateSource(id: "metal.42.100", name: "Game", scope: .application,
                                    processIdentity: .init(pid: 42, startSeconds: 100, startMicroseconds: 0), layerID: "1")
        let reused = FrameRateSource(id: "metal.42.200", name: "Game", scope: .application,
                                     processIdentity: .init(pid: 42, startSeconds: 200, startMicroseconds: 0), layerID: "1")
        var session = FrameRateObservationSession()
        session.begin(source: first, at: start)
        session.ingest([reading(0, source: first), reading(1, source: reused), reading(2)])
        #expect(session.readings.count == 1)
        #expect(session.readings.first?.source == first)
    }

    @Test func deduplicatesBatchesAndKeepsOriginalTimesWithGaps() {
        var session = FrameRateObservationSession()
        session.begin(source: source, at: start)
        session.ingest([reading(2), reading(0), reading(2)])
        session.ingest([reading(0), reading(5), reading(6)])
        #expect(session.readings.map(\.intervalStart) == [0, 2, 5, 6].map { start.addingTimeInterval(Double($0)) })
        #expect(session.readings[2].intervalStart.timeIntervalSince(session.readings[1].intervalEnd) == 2)
        session.ingest((0..<200).map { reading(Double($0) / 4) })
        #expect(session.readings.count == 180)
        #expect(session.readings.first?.intervalStart == start.addingTimeInterval(5))
    }

    @Test func finishFreezesResultsAndMarksUntilNextObservation() {
        var session = FrameRateObservationSession()
        session.begin(source: source, at: start)
        session.mark(at: start.addingTimeInterval(-1))
        session.mark(at: start.addingTimeInterval(1))
        session.ingest([reading(0), reading(2)])
        session.finish(at: start.addingTimeInterval(2))
        session.ingest([reading(2)])
        session.mark(at: start.addingTimeInterval(3))
        #expect(session.readings.count == 1)
        #expect(session.markers.count == 1)
        #expect(session.endedAt == start.addingTimeInterval(2))
        session.begin(source: source, at: start.addingTimeInterval(10))
        #expect(session.readings.isEmpty && session.markers.isEmpty)
        #expect(session.endedAt == nil)
    }

    @Test func doesNotInventFrameTimesFromFPS() {
        #expect(reading(0).frameIntervalMilliseconds == nil)
        let invalid = FrameRateReading(source: source, intervalStart: start, intervalEnd: start,
                                       framesPerSecond: 60, frameIntervalMilliseconds: 16.7)
        #expect(!invalid.isValid)
        let invalidInterval = FrameRateReading(source: source, intervalStart: start, intervalEnd: start.addingTimeInterval(1),
                                               framesPerSecond: 60, frameIntervalMilliseconds: 0)
        #expect(!invalidInterval.isValid)
    }

    @Test func keepsOnlyCompleteWindowsInsideTheSixtySecondObservation() {
        var session = FrameRateObservationSession()
        session.begin(source: source, at: start)
        session.ingest([reading(58), reading(59), reading(59.5), reading(60)])
        session.mark(at: start.addingTimeInterval(60))
        session.mark(at: start.addingTimeInterval(60.1))
        session.finish(at: start.addingTimeInterval(63))
        #expect(session.readings.map(\.intervalEnd) == [59, 60].map { start.addingTimeInterval(Double($0)) })
        #expect(session.markers.count == 1)
        #expect(session.endedAt == start.addingTimeInterval(60))
    }
}
