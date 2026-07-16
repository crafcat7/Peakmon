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
    private var powerCPU: Double { store.value(for: .powerCPU) }
    private var powerGPU: Double { store.value(for: .powerGPU) }
    private var powerPackage: Double { store.value(for: .powerPackage) }
    private var powerSystemSample: MetricSample? { store.latest(for: .powerSystem) }

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
