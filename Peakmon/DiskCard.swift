//
//  DiskCard.swift
//  Peakmon
//
//  Dashboard disk card: used bytes, read/write rates, used %
//  accessory, and a sparkline overlay of disk read/write history.
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

    private var used: Double { store.value(for: .diskUsed) }
    private var total: Double { store.value(for: .diskTotal) }
    private var read: Double { store.value(for: .diskReadRate) }
    private var write: Double { store.value(for: .diskWriteRate) }

    var body: some View {
        let usagePercent = total > 0 ? used / total * 100 : 0
        DashboardCardTemplate(
            title: "Disk",
            systemImage: "internaldrive",
            tint: tint,
            stats: [
                CardStat(label: "Used", value: DashboardFormatting.bytes(used), tint: .cyan),
                CardStat(label: "Read", value: DashboardFormatting.rate(read), tint: .blue),
                CardStat(label: "Write", value: DashboardFormatting.rate(write), tint: .orange),
            ],
            accessory: {
                Text("\(usagePercent, specifier: "%.0f")%")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: usagePercent))
                    .animation(.smooth, value: usagePercent)
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
