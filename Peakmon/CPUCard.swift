//
//  CPUCard.swift
//  Peakmon
//
//  Dashboard CPU card: total + user/system stats, sparkline with
//  toggleable user/system overlays, plus a temperature accessory
//  pulled from the SMC bridge via `thermalCPU`.
//

import PeakmonCore
import PeakmonUI
import SwiftUI

struct CPUCard: View {
    @Environment(MetricsStore.self) private var store
    @Environment(\.cardSettings) private var cardSettings

    @ChartSeriesEnabled(.cpuTotal) private var cpuTotalEnabled
    @ChartSeriesEnabled(.cpuUser) private var cpuUserEnabled
    @ChartSeriesEnabled(.cpuSystem) private var cpuSystemEnabled

    private var tint: Color { cardSettings.tint(.cpu) }

    private var total: Double { store.value(for: .cpuTotal) }
    private var user: Double { store.value(for: .cpuUser) }
    private var system: Double { store.value(for: .cpuSystem) }

    var body: some View {
        DashboardCardTemplate(
            title: "CPU",
            systemImage: "cpu",
            tint: tint,
            stats: [
                CardStat(label: "User", value: String(format: "%.1f%%", user), tint: .blue),
                CardStat(label: "System", value: String(format: "%.1f%%", system), tint: .orange),
            ],
            accessory: {
                let cpuTemp = store.latest(for: .thermalCPU)?.value
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(total, specifier: "%.1f")%")
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText(value: total))
                        .animation(.smooth, value: total)
                    if let cpuTemp, cpuTemp > 0 {
                        Text("\(Int(cpuTemp.rounded()))°C")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            },
            chart: {
                MetricSparklineView(
                    series: sparklineSeries,
                    yMin: 0,
                    yMax: 100,
                )
            },
        )
    }

    /// CPU sparkline payload. Falls back to the total trace when
    /// the user disables every overlay so the chart never blanks.
    private var sparklineSeries: [SparklineSeries] {
        let totalHistory = store.history(for: .cpuTotal)
        let userHistory = store.history(for: .cpuUser)
        let systemHistory = store.history(for: .cpuSystem)
        var lines: [SparklineSeries] = []
        if cpuTotalEnabled {
            lines.append(SparklineSeries(
                id: ChartSeries.cpuTotal.rawValue,
                samples: totalHistory,
                color: ChartSeries.cpuTotal.storedTint,
            ))
        }
        if cpuUserEnabled {
            lines.append(SparklineSeries(
                id: ChartSeries.cpuUser.rawValue,
                samples: userHistory,
                color: ChartSeries.cpuUser.storedTint,
            ))
        }
        if cpuSystemEnabled {
            lines.append(SparklineSeries(
                id: ChartSeries.cpuSystem.rawValue,
                samples: systemHistory,
                color: ChartSeries.cpuSystem.storedTint,
            ))
        }
        if lines.isEmpty {
            lines.append(SparklineSeries(
                id: "cpu.total",
                samples: totalHistory,
                color: tint,
            ))
        }
        return lines
    }
}
