//
//  ThermalCollector.swift
//  PeakmonCollectors
//
//  Surfaces CPU / GPU die temperatures via SMC. Apple Silicon
//  exposes a forest of thermal sensors; we probe a curated subset
//  (`Tp05`/`Tp0D` for CPU, `Tg05`/`Tg0D` for GPU on M3/M4) plus
//  proximity fallbacks (`TC0P`/`TG0P` on older silicon).
//
//  Strategy
//  --------
//  Take the *maximum* of all readable die sensors in each category.
//  Apple's own software (Activity Monitor, powermetrics --samplers
//  thermal) reports the hottest die as the headline number because
//  that's what drives thermal throttling. Averaging would mask
//  hotspots.
//
//  If no die sensors are readable, fall back to the proximity
//  sensor. If even that fails, the collector returns an empty
//  sample list — the dashboard will simply hide the Thermal card.
//

import Foundation
import PeakmonCore

public final class ThermalCollector: MetricCollector {
    public let identifier = "thermal.smc"

    private let state = State()

    public init() {}

    public func collect() async throws -> [MetricSample] {
        await state.sample()
    }

    private actor State {
        private let bridge: SMCBridge? = SMCBridge.shared
        private var discovered = false
        private var cpuKeys: [SMCKey] = []
        private var gpuKeys: [SMCKey] = []

        func sample() -> [MetricSample] {
            guard let bridge else { return [] }
            if !discovered {
                discovered = true
                discoverKeys(bridge: bridge)
            }

            let now = Date.now
            var samples: [MetricSample] = []
            if let cpu = maxReading(bridge: bridge, keys: cpuKeys) {
                samples.append(
                    MetricSample(kind: .thermalCPU, unit: .celsius, value: cpu, timestamp: now),
                )
            }
            if let gpu = maxReading(bridge: bridge, keys: gpuKeys) {
                samples.append(
                    MetricSample(kind: .thermalGPU, unit: .celsius, value: gpu, timestamp: now),
                )
            }
            return samples
        }

        private func discoverKeys(bridge: SMCBridge) {
            // Die sensors first; only fall back to proximity if no
            // die key is readable.
            let cpuDie: [SMCKey] = [.cpuDieP1, .cpuDieP2, .cpuDieP3, .cpuDieP4]
            let gpuDie: [SMCKey] = [.gpuDie1, .gpuDie2]
            cpuKeys = cpuDie.filter { (try? bridge.info($0)) != nil }
            if cpuKeys.isEmpty, (try? bridge.info(.cpuProximity)) != nil {
                cpuKeys = [.cpuProximity]
            }
            gpuKeys = gpuDie.filter { (try? bridge.info($0)) != nil }
            if gpuKeys.isEmpty, (try? bridge.info(.gpuProximity)) != nil {
                gpuKeys = [.gpuProximity]
            }
        }

        private func maxReading(bridge: SMCBridge, keys: [SMCKey]) -> Double? {
            var best: Double?
            for key in keys {
                guard let value = try? bridge.readDouble(key),
                      value.isFinite,
                      value > 0,
                      value < 150
                else { continue }
                best = max(best ?? value, value)
            }
            return best
        }
    }
}
