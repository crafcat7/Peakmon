//
//  FrameRateCollector.swift
//  PeakmonCollectors
//
//  Measures display swaps from the display coprocessor's IOReport
//  counters. The scope is desktop presentation on one display source;
//  it does not identify frames rendered by an individual application.
//

import CoreGraphics
import Foundation
import PeakmonCore

/// Samples desktop presentation rate for one display source.
///
/// An active built-in display uses DCP (or DCP0 on hosts exposing that
/// group). Otherwise the most active external display source is selected.
/// Counters belonging to different display sources are never added.
public final class FrameRateCollector: Sendable {
    private let state = FrameRateState()

    public init() {}

    /// A session fixes its first valid source until reset. Display changes
    /// end the observation instead of joining unrelated sources in a chart.
    public func collectReading() async throws -> FrameRateReading? {
        try await state.collect()
    }

    public func reset() async {
        await state.reset()
    }
}

public enum FrameRateCollectorError: Error, Equatable, Sendable {
    case displayConfigurationChanged
    case sourceUnavailable
}

/// A complete swap subgroup has one event counter for each subframe bucket.
/// Requiring the known shape distinguishes a measured zero from empty or
/// unsupported counter data.
enum FrameRateCounterResolver {
    static let bucketNames = Set((0...10).map { "subframes(\($0))" })

    static func frameCount(from readings: [IOReportBridge.Reading], group: String) -> Int64? {
        guard readings.count == bucketNames.count else { return nil }
        var seen = Set<String>()
        var total: Int64 = 0
        for reading in readings {
            guard reading.group == group,
                  bucketNames.contains(reading.channel),
                  seen.insert(reading.channel).inserted,
                  reading.unit == "events",
                  reading.value >= 0
            else { return nil }
            let addition = total.addingReportingOverflow(reading.value)
            guard !addition.overflow else { return nil }
            total = addition.partialValue
        }
        return total
    }

    static func rate(from readings: [IOReportBridge.Reading], group: String, elapsed: TimeInterval) -> Double? {
        guard elapsed.isFinite, elapsed > 0,
              let count = frameCount(from: readings, group: group)
        else { return nil }
        let value = Double(count) / elapsed
        return value.isFinite ? value : nil
    }
}

enum FrameRateSourceSelection {
    static let builtInGroups = ["DCP", "DCP0"]
    static let externalGroups = ["DCPEXT0", "DCPEXT1", "DCPEXT2", "DCPEXT3"]

    static func group(hasActiveBuiltInDisplay: Bool, rates: [String: Double]) -> String? {
        if hasActiveBuiltInDisplay {
            return builtInGroups.first { validRate(rates[$0]) != nil }
        }
        // An idle, disconnected coprocessor also reports zero. Activity
        // identifies the external source; later zero windows remain valid.
        return externalGroups.compactMap { group -> (String, Double)? in
            guard let rate = validRate(rates[group]), rate > 0 else { return nil }
            return (group, rate)
        }.max { $0.1 < $1.1 }?.0
    }

    private static func validRate(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}

struct FrameRateDisplay: Hashable, Sendable {
    let id: CGDirectDisplayID
    let isBuiltIn: Bool
    let isActive: Bool
}

struct FrameRateDisplayTopology: Equatable, Sendable {
    let displays: [FrameRateDisplay]

    init(displays: [FrameRateDisplay]) {
        self.displays = displays.sorted { $0.id < $1.id }
    }

    var hasActiveBuiltInDisplay: Bool {
        displays.contains { $0.isBuiltIn && $0.isActive }
    }

    var hasActiveExternalDisplay: Bool {
        displays.contains { !$0.isBuiltIn && $0.isActive }
    }

    static func current() -> FrameRateDisplayTopology? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
        return FrameRateDisplayTopology(displays: ids.prefix(Int(count)).map { id in
            FrameRateDisplay(
                id: id,
                isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                isActive: CGDisplayIsActive(id) != 0,
            )
        })
    }
}

private actor FrameRateState {
    private struct Source {
        let bridge: IOReportBridge
        var previous: IOReportBridge.Snapshot
        var previousTime: TimeInterval
    }

    private var topology: FrameRateDisplayTopology?
    private var sources: [Source] = []
    private var lastSubscriptionAttempt: TimeInterval?
    private var selectedGroup: String?
    private static let subscriptionRetryInterval: TimeInterval = 60

    func collect() throws -> FrameRateReading? {
        guard let currentTopology = FrameRateDisplayTopology.current() else {
            reset()
            throw FrameRateCollectorError.sourceUnavailable
        }
        guard topology == currentTopology else {
            if selectedGroup != nil {
                reset()
                throw FrameRateCollectorError.displayConfigurationChanged
            }
            subscribe(for: currentTopology)
            return nil
        }
        guard !sources.isEmpty else {
            let now = ProcessInfo.processInfo.systemUptime
            if lastSubscriptionAttempt.map({ now - $0 >= Self.subscriptionRetryInterval }) ?? true {
                subscribe(for: currentTopology)
            }
            return nil
        }

        var readingsByGroup: [String: FrameRateReading] = [:]
        for index in sources.indices where selectedGroup == nil || sources[index].bridge.group == selectedGroup {
            do {
                let snapshot = try sources[index].bridge.snapshot()
                let now = ProcessInfo.processInfo.systemUptime
                let group = sources[index].bridge.group
                let elapsed = now - sources[index].previousTime
                let readings = snapshot.delta(against: sources[index].previous)
                let rate = FrameRateCounterResolver.rate(
                    from: readings,
                    group: group,
                    elapsed: elapsed,
                )
                sources[index].previous = snapshot
                sources[index].previousTime = now
                if let rate {
                    let end = Date.now
                    readingsByGroup[group] = FrameRateReading(
                        source: FrameRateSource(
                            id: "desktop.\(group)",
                            name: currentTopology.hasActiveBuiltInDisplay ? "Built-in display" : "External display source",
                            scope: .desktop,
                        ),
                        intervalStart: end.addingTimeInterval(-elapsed),
                        intervalEnd: end,
                        framesPerSecond: rate,
                    )
                }
            } catch { continue }
        }

        if let selectedGroup {
            guard let reading = readingsByGroup[selectedGroup] else {
                reset()
                throw FrameRateCollectorError.sourceUnavailable
            }
            return reading
        }
        let group = FrameRateSourceSelection.group(
            hasActiveBuiltInDisplay: currentTopology.hasActiveBuiltInDisplay,
            rates: readingsByGroup.mapValues(\.framesPerSecond),
        )
        guard let group, let reading = readingsByGroup[group] else {
            if readingsByGroup.isEmpty { reset() }
            return nil
        }
        selectedGroup = group
        return reading
    }

    func reset() {
        topology = nil
        sources.removeAll()
        lastSubscriptionAttempt = nil
        selectedGroup = nil
    }

    private func subscribe(for currentTopology: FrameRateDisplayTopology) {
        reset()
        topology = currentTopology
        lastSubscriptionAttempt = ProcessInfo.processInfo.systemUptime
        let groups: [String]
        if currentTopology.hasActiveBuiltInDisplay {
            groups = FrameRateSourceSelection.builtInGroups
        } else if currentTopology.hasActiveExternalDisplay {
            groups = FrameRateSourceSelection.externalGroups
        } else {
            return
        }

        for group in groups {
            do {
                let bridge = try IOReportBridge(group: group, subGroup: "swap")
                let baseline = try bridge.snapshot()
                guard FrameRateCounterResolver.frameCount(
                    from: baseline.delta(against: baseline),
                    group: group,
                ) != nil else { continue }
                sources.append(Source(
                    bridge: bridge,
                    previous: baseline,
                    previousTime: ProcessInfo.processInfo.systemUptime,
                ))
                if currentTopology.hasActiveBuiltInDisplay {
                    break
                }
            } catch {
                continue
            }
        }
    }
}
