//
//  PowerSampler.swift
//  PeakmonCollectors
//
//  Reports per-subsystem power draw (CPU / GPU / ANE / DRAM / Package)
//  in watts by subscribing to the IOReport "Energy Model" group.
//
//  The "Energy Model" group exposes ~325 channels on Apple Silicon, all
//  in millijoules. Each tick we capture a fresh snapshot, diff it
//  against the previous one to get ΔmJ for the elapsed wall-clock
//  window, then divide by that window to convert to mJ/s = mW, and
//  finally by 1000 to land on watts.
//
//  Channel aggregation follows what `powermetrics --samplers cpu_power
//  gpu_power ane_power` prints:
//
//    CPU      = EACC_* + PACC*_* (energy + SRAM rails per cluster)
//    GPU      = GPU0 + GPU CS0 + GPU SRAM0 + GPU CS SRAM0
//    ANE      = ANE0
//    DRAM     = DCS0
//    Package  = sum of the above
//
//  Anything else in the group (display, network PHYs, secondary
//  accelerators) is ignored — the goal here is the same five totals
//  users see in Activity Monitor's Energy tab and on Apple's spec
//  sheets, not a full per-rail breakdown.
//
//  Public API of PeakmonCollectors — no entitlement, no sudo. Uses the
//  ad-hoc-friendly `IOReportBridge` from PeakmonCore, which dlopens
//  /usr/lib/libIOReport.dylib at runtime. If the bridge fails to
//  construct (missing dylib / symbols), the collector publishes nothing
//  and the rest of the app keeps running normally.
//

import Foundation
import PeakmonCore

/// Samples per-subsystem energy counters and emits watts.
public final class PowerCollector: MetricCollector {
    public let identifier = "power.ioreport"

    /// `Bridge + previous snapshot + previous timestamp` mutated under
    /// the actor lock. `nil` either before the first tick or whenever
    /// the bridge could not be constructed (in which case `collect()`
    /// returns `[]` quietly).
    private let state = State()

    public init() {}

    public func collect() async throws -> [MetricSample] {
        await state.sample()
    }

    // MARK: - Actor state

    private actor State {
        private var bridge: IOReportBridge?
        private var previous: IOReportBridge.Snapshot?
        private var previousAt: Date?
        private var bridgeAttempted = false

        func sample() -> [MetricSample] {
            // Lazy construct on first call so a missing dylib does not
            // crash app launch; cache the result either way.
            if !bridgeAttempted {
                bridgeAttempted = true
                do {
                    bridge = try IOReportBridge(group: "Energy Model")
                } catch {
                    Log.collectors.error(
                        // swiftlint:disable:next line_length
                        "PowerCollector disabled: \(String(describing: error), privacy: .public)",
                    )
                    bridge = nil
                }
            }
            guard let bridge else { return [] }

            let now = Date.now
            let snapshot: IOReportBridge.Snapshot
            do {
                snapshot = try bridge.snapshot()
            } catch {
                Log.collectors.error(
                    "PowerCollector snapshot failed: \(String(describing: error), privacy: .public)",
                )
                return []
            }

            defer {
                previous = snapshot
                previousAt = now
            }
            guard let previous, let previousAt else {
                // First tick — establish a baseline, emit nothing.
                return []
            }

            let elapsed = now.timeIntervalSince(previousAt)
            guard elapsed > 0 else { return [] }

            let readings = snapshot.delta(against: previous)
            guard !readings.isEmpty else { return [] }

            var cpuMJ: Int64 = 0
            var gpuMJ: Int64 = 0
            var aneMJ: Int64 = 0
            var dramMJ: Int64 = 0

            for reading in readings {
                guard reading.unit == "mJ" else { continue }
                let name = reading.channel
                if name.hasPrefix("EACC") || name.hasPrefix("PACC") {
                    cpuMJ &+= reading.value
                } else if name == "GPU0"
                    || name == "GPU CS0"
                    || name == "GPU SRAM0"
                    || name == "GPU CS SRAM0"
                {
                    gpuMJ &+= reading.value
                } else if name == "ANE0" {
                    aneMJ &+= reading.value
                } else if name == "DCS0" {
                    dramMJ &+= reading.value
                }
            }
            let packageMJ = cpuMJ &+ gpuMJ &+ aneMJ &+ dramMJ

            func watts(_ mJ: Int64) -> Double {
                Double(mJ) / elapsed / 1000.0
            }

            return [
                MetricSample(kind: .powerCPU, unit: .watts, value: watts(cpuMJ), timestamp: now),
                MetricSample(kind: .powerGPU, unit: .watts, value: watts(gpuMJ), timestamp: now),
                MetricSample(kind: .powerANE, unit: .watts, value: watts(aneMJ), timestamp: now),
                MetricSample(kind: .powerDRAM, unit: .watts, value: watts(dramMJ), timestamp: now),
                MetricSample(
                    kind: .powerPackage,
                    unit: .watts,
                    value: watts(packageMJ),
                    timestamp: now,
                ),
            ]
        }
    }
}
