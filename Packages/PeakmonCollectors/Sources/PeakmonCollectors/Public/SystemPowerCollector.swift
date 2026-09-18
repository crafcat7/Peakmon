//
//  SystemPowerCollector.swift
//  PeakmonCollectors
//
//  Surfaces the SMC system-rate reading as whole-machine power. This is
//  an undocumented hardware counter; it is not Activity Monitor's
//  dimensionless Energy Impact score. It complements
//  `PowerCollector`, which reports SoC-internal CPU/GPU rails from
//  IOReport but does NOT include the display panel, Wi-Fi/BT radios,
//  Thunderbolt PHYs, SSD, or fans.
//
//  ## Aggregation strategy
//
//  Read `PSTR` (System Total Rate) directly. If it is missing or a read
//  fails, explicitly invalidate the current value so a previous sample
//  cannot remain on screen indefinitely.
//
//  We deliberately do NOT synthesise from `PDTR` (Adapter Delivery)
//  + `BATP` (Battery Power): PDTR includes adapter→battery charging
//  current, which is not "system" power, and the BATP sign
//  convention is undocumented and varies by model. Any synthesised
//  number would be wrong in at least one common case (e.g. charging
//  while running). Better to show nothing than a confidently-wrong
//  headline.
//

import Foundation
import PeakmonCore

/// Samples whole-machine power via SMC. Falls back gracefully when
/// the requisite keys are unavailable on the host.
public final class SystemPowerCollector: MetricCollector {
    public let identifier = "power.smc"

    private let state = State()

    public init() {}

    public func collect() async throws -> [MetricSample] {
        await state.sample()
    }

    static func makeSample(value: Double?, timestamp: Date) -> MetricSample {
        guard let value, value.isFinite, value >= 0 else {
            return .unavailable(kind: .powerSystem, unit: .watts, timestamp: timestamp)
        }
        return MetricSample(kind: .powerSystem, unit: .watts, value: value, timestamp: timestamp)
    }

    private actor State {
        private let bridge: SMCBridge? = SMCBridge.shared
        private var prepared = false
        private var strategy: Strategy = .unknown

        func sample() -> [MetricSample] {
            if !prepared {
                prepared = true
                strategy = decideStrategy()
            }
            let now = Date.now
            guard let bridge else {
                return [SystemPowerCollector.makeSample(value: nil, timestamp: now)]
            }

            guard strategy == .systemTotal,
                  let value = try? bridge.readDouble(.systemTotal)
            else { return [SystemPowerCollector.makeSample(value: nil, timestamp: now)] }
            return [SystemPowerCollector.makeSample(value: value, timestamp: now)]
        }

        private func decideStrategy() -> Strategy {
            guard let bridge else { return .unknown }
            if (try? bridge.info(.systemTotal)) != nil {
                return .systemTotal
            }
            return .unknown
        }

    }

    private enum Strategy {
        case systemTotal
        case unknown
    }
}
