//
//  PowerCard.swift
//  Peakmon
//
//  Dashboard power card: per-rail watts (CPU / GPU), a system
//  total accessory, the DRAM / DISPLAY / fan secondary row, and a
//  toggleable CPU / GPU sparkline overlay.
//

import PeakmonCore
import PeakmonUI
import SwiftUI

struct PowerCard: View {
    @Environment(MetricsStore.self) private var store
    @Environment(\.cardSettings) private var cardSettings

    @ChartSeriesEnabled(.powerCPU) private var powerCPUEnabled
    @ChartSeriesEnabled(.powerGPU) private var powerGPUEnabled

    private var tint: Color { cardSettings.tint(.power) }
    private var powerCPU: Double { store.value(for: .powerCPU) }
    private var powerGPU: Double { store.value(for: .powerGPU) }
    private var powerPackage: Double { store.value(for: .powerPackage) }
    private var powerSystemSample: MetricSample? { store.latest(for: .powerSystem) }
    private var powerDRAM: Double { store.value(for: .powerDRAM) }
    private var powerDisplay: Double { store.value(for: .powerDisplay) }

    var body: some View {
        DashboardCardTemplate(
            title: "Power",
            systemImage: "bolt.fill",
            tint: tint,
            stats: [
                CardStat(label: "CPU", value: DashboardFormatting.watts(powerCPU), tint: .blue),
                CardStat(label: "GPU", value: DashboardFormatting.watts(powerGPU), tint: .indigo),
            ],
            accessory: {
                let headlineWatts = powerSystemSample?.value ?? powerPackage
                Text(DashboardFormatting.watts(headlineWatts))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: headlineWatts))
                    .animation(.smooth, value: headlineWatts)
            },
            chart: {
                VStack(spacing: 4) {
                    subsystemRow
                    MetricSparklineView(
                        series: sparklineSeries,
                        yMin: 0,
                        yMax: nil,
                    )
                }
            },
        )
    }

    /// Secondary detail row: surfaces SoC sub-rails IOReport
    /// exposes beyond CPU+GPU so the gap between the SMC "system"
    /// headline and the IOReport "package" subtotal is at least
    /// partially explained. Rails that long-term report 0 W
    /// (channel power-gated, missing on this SoC, or only
    /// reported under load) are dimmed and shown as "—" instead of
    /// "0.0 W" to avoid misleading users into thinking the
    /// subsystem is genuinely idle.
    ///
    /// Fan slots are detected at runtime: FanCollector probes SMC
    /// keys F0Ac/F1Ac on first sample and only emits samples for
    /// keys that exist on this hardware. We mirror that here:
    ///   - both present  -> two cells: "FAN-L" + "FAN-R"
    ///   - only F0       -> single cell labelled "FAN" (M4 14"
    ///                      MacBook Pro and other single-fan
    ///                      models — labelling it "FAN-L" would
    ///                      misleadingly imply a missing "FAN-R")
    ///   - neither       -> no fan cell (fanless designs like the
    ///                      MacBook Air / base Mac mini)
    private var subsystemRow: some View {
        HStack(spacing: 0) {
            subsystemCell(label: "DISP", watts: powerDisplay)
            subsystemCell(label: "DRAM", watts: powerDRAM)
            let hasLeft = store.hasHistory(for: .fanLeftRPM)
            let hasRight = store.hasHistory(for: .fanRightRPM)
            if hasLeft, hasRight {
                fanCell(label: "FAN-L", kind: .fanLeftRPM)
                fanCell(label: "FAN-R", kind: .fanRightRPM)
            } else if hasLeft {
                fanCell(label: "FAN", kind: .fanLeftRPM)
            } else if hasRight {
                fanCell(label: "FAN", kind: .fanRightRPM)
            }
        }
    }

    /// Fan cell shows RPM as an integer. Machines that only expose
    /// one fan (or none) render the missing slot as a dimmed "—".
    @ViewBuilder
    private func fanCell(label: String, kind: MetricKind) -> some View {
        let rpm = store.latest(for: kind)?.value
        let inactive = rpm == nil || (rpm ?? 0) < 1
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(inactive ? "—" : "\(Int(rpm ?? 0))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(inactive ? .tertiary : .secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func subsystemCell(label: String, watts: Double) -> some View {
        let inactive = watts < 0.01
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(inactive ? "—" : DashboardFormatting.watts(watts))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(inactive ? .tertiary : .secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Power sparkline payload. Overlays whichever of the sub-rails
    /// the user has enabled. Falls back to the CPU rail so the
    /// chart never goes blank.
    private var sparklineSeries: [SparklineSeries] {
        var lines: [SparklineSeries] = []
        if powerCPUEnabled {
            lines.append(SparklineSeries(
                id: ChartSeries.powerCPU.rawValue,
                samples: store.history(for: .powerCPU),
                color: ChartSeries.powerCPU.storedTint,
            ))
        }
        if powerGPUEnabled {
            lines.append(SparklineSeries(
                id: ChartSeries.powerGPU.rawValue,
                samples: store.history(for: .powerGPU),
                color: ChartSeries.powerGPU.storedTint,
            ))
        }
        if lines.isEmpty {
            lines.append(SparklineSeries(
                id: "power.cpu",
                samples: store.history(for: .powerCPU),
                color: tint,
            ))
        }
        return lines
    }
}
