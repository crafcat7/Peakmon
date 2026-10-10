import Foundation
@testable import PeakmonCollectors
import PeakmonCore
import Testing

@Suite("FrameRateCollector")
struct FrameRateCollectorTests {
    private func readings(group: String = "DCP", values: [Int64] = [Int64](repeating: 0, count: 11)) -> [IOReportBridge.Reading] {
        values.enumerated().map { index, value in
            IOReportBridge.Reading(group: group, channel: "subframes(\(index))", unit: "events", value: value)
        }
    }

    @Test func distinguishesMissingCountersFromMeasuredZero() {
        #expect(FrameRateCounterResolver.rate(from: [], group: "DCP", elapsed: 1) == nil)
        #expect(FrameRateCounterResolver.rate(from: readings(), group: "DCP", elapsed: 1) == 0)
        #expect(FrameRateCounterResolver.rate(from: Array(readings().dropLast()), group: "DCP", elapsed: 1) == nil)
    }

    @Test func addsBucketsWithinOneDisplaySourceAndUsesActualElapsedTime() {
        let counters = readings(values: [0, 30, 0, 20, 0, 10, 0, 0, 0, 0, 0])
        #expect(FrameRateCounterResolver.rate(from: counters, group: "DCP", elapsed: 2) == 30)
    }

    @Test func rejectsResetCountersAndInvalidElapsedTime() {
        let negative = readings(values: [0, -1, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(FrameRateCounterResolver.rate(from: negative, group: "DCP", elapsed: 1) == nil)
        for elapsed in [0.0, -1.0, Double.nan, Double.infinity] {
            #expect(FrameRateCounterResolver.rate(from: readings(), group: "DCP", elapsed: elapsed) == nil)
        }
        let overflow = readings(values: [Int64.max, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(FrameRateCounterResolver.rate(from: overflow, group: "DCP", elapsed: 1) == nil)
    }

    @Test func rejectsWrongScopeUnitsAndDuplicateBuckets() {
        #expect(FrameRateCounterResolver.frameCount(from: readings(group: "DCPEXT0"), group: "DCP") == nil)
        var counters = readings()
        counters[0] = IOReportBridge.Reading(group: "DCP", channel: "subframes(0)", unit: "us", value: 0)
        #expect(FrameRateCounterResolver.frameCount(from: counters, group: "DCP") == nil)
        counters = readings()
        counters[0] = counters[1]
        #expect(FrameRateCounterResolver.frameCount(from: counters, group: "DCP") == nil)
    }

    @Test func prefersBuiltInSourceIncludingValidZeroAndFallsBackToDCP0() {
        let rates = ["DCP": 0.0, "DCP0": 60, "DCPEXT0": 120]
        #expect(FrameRateSourceSelection.group(hasActiveBuiltInDisplay: true, rates: rates) == "DCP")
        #expect(FrameRateSourceSelection.group(hasActiveBuiltInDisplay: true, rates: ["DCP0": 60, "DCPEXT0": 120]) == "DCP0")
        #expect(FrameRateSourceSelection.group(hasActiveBuiltInDisplay: true, rates: ["DCPEXT0": 120]) == nil)
    }

    @Test func selectsMostActiveExternalDisplayWithoutAddingRates() {
        let rates = ["DCP": 120.0, "DCPEXT0": 60, "DCPEXT1": 90, "DCPEXT2": 0]
        #expect(FrameRateSourceSelection.group(hasActiveBuiltInDisplay: false, rates: rates) == "DCPEXT1")
        #expect(FrameRateSourceSelection.group(hasActiveBuiltInDisplay: false, rates: ["DCPEXT0": 0]) == nil)
        #expect(FrameRateSourceSelection.group(hasActiveBuiltInDisplay: false, rates: ["DCPEXT0": .nan, "DCPEXT1": -1]) == nil)
    }

    @Test func topologyTracksDisplayIdentityAndActiveBuiltInState() {
        let builtIn = FrameRateDisplay(id: 1, isBuiltIn: true, isActive: true)
        let external = FrameRateDisplay(id: 2, isBuiltIn: false, isActive: true)
        let topology = FrameRateDisplayTopology(displays: [builtIn, external])
        #expect(topology == FrameRateDisplayTopology(displays: [external, builtIn]))
        #expect(topology.hasActiveBuiltInDisplay)
        #expect(topology.hasActiveExternalDisplay)
        #expect(topology != FrameRateDisplayTopology(displays: [FrameRateDisplay(id: 1, isBuiltIn: true, isActive: false), external]))
        #expect(topology != FrameRateDisplayTopology(displays: [builtIn, FrameRateDisplay(id: 3, isBuiltIn: false, isActive: true)]))
    }

}
