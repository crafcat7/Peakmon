//
//  FanCollector.swift
//  PeakmonCollectors
//
//  Reports per-fan speed (RPM) via SMC. Fanless Apple Silicon
//  machines (MacBook Air, base Mac mini, iPad Pro M-series) lack
//  the `F0Ac` key entirely; on those hosts the collector emits
//  nothing and the dashboard never shows a Fan card.
//
//  Multi-fan machines (MacBook Pro 16", Mac Studio, iMac) expose
//  each fan separately as `F0Ac` (left / intake) and `F1Ac`
//  (right / exhaust). The two can differ by hundreds of RPM under
//  asymmetric workloads — e.g. a video encode pinned to one
//  cluster — so we publish them as distinct metrics rather than
//  collapsing to a single max.
//
//  Mac Pro can have 4+ fans; the bridge currently only knows about
//  F0/F1 — extend `SMCKey` and add `.fanRPM2`/`.fanRPM3` here if a
//  Mac Pro user needs them.
//

import Foundation
import PeakmonCore

public final class FanCollector: MetricCollector {
    public let identifier = "fan.smc"

    private let state = State()

    public init() {}

    public func collect() async throws -> [MetricSample] {
        await state.sample()
    }

    private actor State {
        private let bridge: SMCBridge? = SMCBridge.shared
        private var discovered = false
        private var hasFan0 = false
        private var hasFan1 = false

        func sample() -> [MetricSample] {
            guard let bridge else { return [] }
            if !discovered {
                discovered = true
                hasFan0 = (try? bridge.info(.fan0Actual)) != nil
                hasFan1 = (try? bridge.info(.fan1Actual)) != nil
            }

            let now = Date.now
            var samples: [MetricSample] = []
            if hasFan0, let v = try? bridge.readDouble(.fan0Actual), v >= 0 {
                samples.append(
                    MetricSample(kind: .fanLeftRPM, unit: .rpm, value: v, timestamp: now),
                )
            }
            if hasFan1, let v = try? bridge.readDouble(.fan1Actual), v >= 0 {
                samples.append(
                    MetricSample(kind: .fanRightRPM, unit: .rpm, value: v, timestamp: now),
                )
            }
            return samples
        }
    }
}
