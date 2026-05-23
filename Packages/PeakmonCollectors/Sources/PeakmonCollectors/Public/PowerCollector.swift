//
//  PowerSampler.swift
//  PeakmonCollectors
//
//  Reports per-subsystem power draw (CPU / GPU / Package) in watts by
//  subscribing to the IOReport "Energy Model" group.
//
//  The "Energy Model" group exposes ~325 channels on Apple Silicon, all
//  in millijoules. Each tick we capture a fresh snapshot, diff it
//  against the previous one to get ΔmJ for the elapsed wall-clock
//  window, then divide by that window to convert to mJ/s = mW, and
//  finally by 1000 to land on watts.
//
//  Channel aggregation (channel-name suffix `0` is stripped first so
//  M3-style `GPU0` and M4-style `GPU` reach the same branch):
//
//    CPU      = "CPU Energy" if present (SoC-provided sum) else
//               EACC_CPUn + PACCx_CPUn leaves
//               (cluster summary rows EACC_CPU / PACCx_CPU are
//                skipped to avoid double-counting their children)
//    GPU      = GPU + GPU CS + GPU SRAM + GPU CS SRAM if present,
//               else fall back to "GPU Energy" (in nJ → /1e6 mJ)
//    DRAM     = DCS + DRAM + AMCC                  (memory PHY + fabric)
//    Display  = DISP + DISPEXT                     (internal + external)
//    Package  = CPU + GPU                          (Activity-Monitor-style total)
//
//  ANE and the media engines (ISP / AVE / MSR / VDEC) are intentionally
//  not broken out: their Energy Model channels sit at a steady 0 W
//  when the block is power-gated (the default) and only briefly spike
//  under specific workloads, which adds noise to the dashboard
//  without telling users anything actionable. The SMC system headline
//  emitted by SystemPowerCollector already captures their contribution
//  to total draw.
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

    /// Bridge + previous-snapshot cache, guarded by an actor.
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
            if !bridgeAttempted {
                bridgeAttempted = true
                bridge = try? IOReportBridge(group: "Energy Model")
            }
            guard let bridge else { return [] }

            let now = Date.now
            guard let snapshot = try? bridge.snapshot() else { return [] }

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

            let agg = Self.aggregate(readings: readings)

            func watts(_ mJ: Int64) -> Double {
                Double(mJ) / elapsed / 1000.0
            }

            return [
                MetricSample(kind: .powerCPU, unit: .watts, value: watts(agg.cpuMJ), timestamp: now),
                MetricSample(kind: .powerGPU, unit: .watts, value: watts(agg.gpuMJ), timestamp: now),
                MetricSample(kind: .powerDRAM, unit: .watts, value: watts(agg.dramMJ), timestamp: now),
                MetricSample(
                    kind: .powerDisplay,
                    unit: .watts,
                    value: watts(agg.displayMJ),
                    timestamp: now,
                ),
                MetricSample(
                    kind: .powerPackage,
                    unit: .watts,
                    value: watts(agg.cpuMJ + agg.gpuMJ),
                    timestamp: now,
                ),
            ]
        }

        /// Per-rail energy totals for a single delta window (mJ).
        private struct Aggregation {
            var cpuMJ: Int64 = 0
            var gpuMJ: Int64 = 0
            var dramMJ: Int64 = 0
            var displayMJ: Int64 = 0
        }

        /// Walk the channel deltas once and produce a per-rail energy
        /// total. Aggregation rules are documented at the top of this
        /// file; the only subtlety in code is the trailing-`0` strip
        /// that lets M3-style `GPU0` and M4-style `GPU` hit the same
        /// branch.
        private static func aggregate(readings: [IOReportBridge.Reading]) -> Aggregation {
            var agg = Aggregation()
            var cpuLeafMJ: Int64 = 0
            var gpuEnergyMJ: Int64 = 0
            var hasCPUSummary = false

            for reading in readings {
                let name = reading.channel
                let base = name.hasSuffix("0") ? String(name.dropLast()) : name
                switch reading.unit {
                case "mJ":
                    if name == "CPU Energy" {
                        agg.cpuMJ = reading.value
                        hasCPUSummary = true
                    } else if (name.hasPrefix("EACC_CPU") || name.hasPrefix("PACC"))
                        // Skip cluster summary rows so leaves can sum
                        // without overlap.
                        && name != "EACC_CPU"
                        && !(name.hasPrefix("PACC") && name.hasSuffix("_CPU"))
                    {
                        cpuLeafMJ += reading.value
                    } else if base == "GPU"
                        || base == "GPU CS"
                        || base == "GPU SRAM"
                        || base == "GPU CS SRAM"
                    {
                        agg.gpuMJ += reading.value
                    } else if base == "DCS" || base == "DRAM" || base == "AMCC" {
                        agg.dramMJ += reading.value
                    } else if base == "DISP" || base == "DISPEXT" {
                        agg.displayMJ += reading.value
                    }
                case "nJ":
                    if name == "GPU Energy" {
                        gpuEnergyMJ = reading.value / 1_000_000
                    }
                default:
                    continue
                }
            }
            if !hasCPUSummary { agg.cpuMJ = cpuLeafMJ }
            if agg.gpuMJ == 0 { agg.gpuMJ = gpuEnergyMJ }
            return agg
        }
    }
}
