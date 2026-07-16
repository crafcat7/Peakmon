//
//  DiskCard.swift
//  Peakmon
//
//  Popover disk card: current total throughput, read/write rates,
//  and a sparkline overlay of disk read/write history.
//

import PeakmonCore
import PeakmonUI
import SwiftUI

struct DiskCard: View {
    @Environment(MetricsStore.self) private var store
    @Environment(\.cardSettings) private var cardSettings

    @ChartSeriesEnabled(.diskRead) private var diskReadEnabled
    @ChartSeriesEnabled(.diskWrite) private var diskWriteEnabled

    private var tint: Color { cardSettings.tint(.disk) }

    private var read: Double { store.value(for: .diskReadRate) }
    private var write: Double { store.value(for: .diskWriteRate) }

    var body: some View {
        let totalRate = read + write
        DashboardCardTemplate(
            title: "Disk",
            systemImage: "internaldrive",
            tint: tint,
            stats: [
                CardStat(label: "Read", value: DashboardFormatting.rateShort(read), tint: .blue),
                CardStat(label: "Write", value: DashboardFormatting.rateShort(write), tint: .orange),
            ],
            accessory: {
                Text(DashboardFormatting.rateHeadline(totalRate))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: totalRate))
                    .animation(.smooth, value: totalRate)
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
        if diskReadEnabled {
            lines.append(SparklineSeries(
                id: ChartSeries.diskRead.rawValue,
                samples: store.history(for: .diskReadRate),
                color: ChartSeries.diskRead.storedTint,
            ))
        }
        if diskWriteEnabled {
            lines.append(SparklineSeries(
                id: ChartSeries.diskWrite.rawValue,
                samples: store.history(for: .diskWriteRate),
                color: ChartSeries.diskWrite.storedTint,
            ))
        }
        if lines.isEmpty {
            lines.append(SparklineSeries(
                id: "disk.read",
                samples: store.history(for: .diskReadRate),
                color: tint,
            ))
        }
        return lines
    }
}
