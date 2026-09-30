//
//  PowerCard.swift
//  Peakmon
//
//  Popover power card: CPU/GPU watts, a system-total accessory,
//  and a toggleable CPU/GPU sparkline overlay. Detailed subsystem
//  rails stay on the main dashboard where they have enough room.
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
    private let liveMaximumAge: TimeInterval = 8
    private var cpuSample: MetricSample? {
        store.latest(for: .powerCPU, maximumAge: liveMaximumAge)
            ?? store.latest(for: .powerCPUSupply, maximumAge: liveMaximumAge)
    }
    private var powerCPU: Double? { cpuSample?.value }
    private var cpuLabel: String { cpuSample?.kind == .powerCPUSupply ? "CPU supply" : "CPU" }
    private var powerGPU: Double? { store.latest(for: .powerGPU, maximumAge: liveMaximumAge)?.value }
    private var headlineSample: MetricSample? {
        store.latest(for: .powerSystem, maximumAge: liveMaximumAge)
            ?? store.latest(for: .powerPackage, maximumAge: liveMaximumAge)
    }
    private var totalWatts: Double? { headlineSample?.value }
    private var headlineScope: String? {
        switch headlineSample?.kind {
        case .powerSystem: "System"
        case .powerPackage: "SoC package"
        default: nil
        }
    }

    var body: some View {
        DashboardCardTemplate(
            title: "Power",
            systemImage: "bolt.fill",
            tint: tint,
            stats: [
                CardStat(label: cpuLabel, value: powerCPU.map(DashboardFormatting.watts) ?? "—", tint: .blue),
                CardStat(label: "GPU", value: powerGPU.map(DashboardFormatting.watts) ?? "—", tint: .indigo),
            ],
            accessory: {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(totalWatts.map(DashboardFormatting.watts) ?? "—")
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText(value: totalWatts ?? 0))
                        .animation(.smooth, value: totalWatts)
                    if let headlineScope {
                        Text(LocalizedStringKey(headlineScope))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            },
            chart: {
                MetricSparklineView(
                    series: sparklineSeries,
                    yMin: 0,
                    yMax: nil,
                )
            },
        )
    }

    /// Power sparkline payload. Overlays whichever of the sub-rails
    /// the user has enabled. Falls back to the CPU rail so the
    /// chart never goes blank.
    private var sparklineSeries: [SparklineSeries] {
        var lines: [SparklineSeries] = []
        if powerCPUEnabled {
            let kind = cpuSample?.kind ?? .powerCPU
            lines.append(SparklineSeries(
                id: ChartSeries.powerCPU.rawValue,
                samples: store.history(for: kind),
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
            let kind = cpuSample?.kind ?? .powerCPU
            lines.append(SparklineSeries(
                id: "power.cpu",
                samples: store.history(for: kind),
                color: tint,
            ))
        }
        return lines
    }
}
