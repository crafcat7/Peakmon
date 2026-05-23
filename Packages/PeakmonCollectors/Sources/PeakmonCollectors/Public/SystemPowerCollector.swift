//
//  SystemPowerCollector.swift
//  PeakmonCollectors
//
//  Surfaces **whole-machine** power draw — i.e. the same number
//  Activity Monitor's "Energy" tab and Apple's spec sheets quote —
//  by reading SMC keys via `SMCBridge`. This complements
//  `PowerCollector`, which reports SoC-internal CPU/GPU rails from
//  IOReport but does NOT include the display panel, Wi-Fi/BT radios,
//  Thunderbolt PHYs, SSD, fans, or AC adapter conversion losses.
//
//  ## Aggregation strategy
//
//  Read `PSTR` (System Total Rate) directly. Every Apple Silicon Mac
//  we've tested (M1/M2/M3/M4 across MacBook Air/Pro, Mac mini, Mac
//  Studio) exposes this key, and on Intel Macs it has been present
//  since at least 2013. If `PSTR` is missing the collector emits
//  nothing and the dashboard's existing `powerPackage` (IOReport
//  SoC subtotal) remains the headline.
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

    private actor State {
        private let bridge: SMCBridge? = SMCBridge.shared
        private var prepared = false
        private var strategy: Strategy = .unknown

        func sample() -> [MetricSample] {
            if !prepared {
                prepared = true
                strategy = decideStrategy()
            }
            guard let bridge else { return [] }

            guard strategy == .systemTotal,
                  let value = try? bridge.readDouble(.systemTotal)
            else { return [] }
            let watts = max(0, value)

            return [
                MetricSample(
                    kind: .powerSystem,
                    unit: .watts,
                    value: watts,
                    timestamp: Date.now,
                ),
            ]
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
