//
//  NetworkCard.swift
//  Peakmon
//
//  Dashboard network card: down/up rates, combined throughput
//  accessory, and a sparkline overlay of inbound/outbound history.
//

import PeakmonCore
import PeakmonUI
import SwiftUI

struct NetworkCard: View {
    @Environment(MetricsStore.self) private var store
    @Environment(\.cardSettings) private var cardSettings

    @ChartSeriesEnabled(.netIn) private var netInEnabled
    @ChartSeriesEnabled(.netOut) private var netOutEnabled

    private var tint: Color { cardSettings.tint(.network) }
    private var netIn: Double { store.value(for: .netInRate) }
    private var netOut: Double { store.value(for: .netOutRate) }

    var body: some View {
        DashboardCardTemplate(
            title: "Network",
            systemImage: "network",
            tint: tint,
            stats: [
                CardStat(label: "Down", value: DashboardFormatting.rate(netIn), tint: .green),
                CardStat(label: "Up", value: DashboardFormatting.rate(netOut), tint: .pink),
            ],
            accessory: {
                let total = netIn + netOut
                Text(DashboardFormatting.rate(total))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: total))
                    .animation(.smooth, value: total)
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

    private var sparklineSeries: [SparklineSeries] {
        var lines: [SparklineSeries] = []
        if netInEnabled {
            lines.append(SparklineSeries(
                id: ChartSeries.netIn.rawValue,
                samples: store.history(for: .netInRate),
                color: ChartSeries.netIn.storedTint,
            ))
        }
        if netOutEnabled {
            lines.append(SparklineSeries(
                id: ChartSeries.netOut.rawValue,
                samples: store.history(for: .netOutRate),
                color: ChartSeries.netOut.storedTint,
            ))
        }
        if lines.isEmpty {
            lines.append(SparklineSeries(
                id: "net.in",
                samples: store.history(for: .netInRate),
                color: tint,
            ))
        }
        return lines
    }
}
