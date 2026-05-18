//
//  DashboardView+Series.swift
//  Peakmon
//
//  Builds the multi-series payload arrays consumed by each
//  dashboard sparkline. Lives in an extension to keep
//  `DashboardView` itself under SwiftLint's `type_body_length`
//  ceiling.
//

import PeakmonCore
import PeakmonUI
import SwiftUI

extension DashboardView {
    /// CPU sparkline payload. Falls back to `cpuTotal` so the chart
    /// never goes blank if the user disables every CPU series.
    var cpuSparklineSeries: [SparklineSeries] {
        var lines: [SparklineSeries] = []
        if cpuTotalEnabled {
            lines.append(SparklineSeries(
                id: ChartSeries.cpuTotal.rawValue,
                samples: history,
                color: ChartSeries.cpuTotal.storedTint,
            ))
        }
        if cpuUserEnabled {
            lines.append(SparklineSeries(
                id: ChartSeries.cpuUser.rawValue,
                samples: cpuUserHistory,
                color: ChartSeries.cpuUser.storedTint,
            ))
        }
        if cpuSystemEnabled {
            lines.append(SparklineSeries(
                id: ChartSeries.cpuSystem.rawValue,
                samples: cpuSystemHistory,
                color: ChartSeries.cpuSystem.storedTint,
            ))
        }
        if lines.isEmpty {
            lines.append(SparklineSeries(
                id: "cpu.total",
                samples: history,
                color: cpuTint,
            ))
        }
        return lines
    }

    var diskSparklineSeries: [SparklineSeries] {
        var lines: [SparklineSeries] = []
        if diskReadEnabled {
            lines.append(SparklineSeries(
                id: ChartSeries.diskRead.rawValue,
                samples: diskReadHistory,
                color: ChartSeries.diskRead.storedTint,
            ))
        }
        if diskWriteEnabled {
            lines.append(SparklineSeries(
                id: ChartSeries.diskWrite.rawValue,
                samples: diskWriteHistory,
                color: ChartSeries.diskWrite.storedTint,
            ))
        }
        if lines.isEmpty {
            lines.append(SparklineSeries(
                id: "disk.read",
                samples: diskReadHistory,
                color: diskTint,
            ))
        }
        return lines
    }

    var networkSparklineSeries: [SparklineSeries] {
        var lines: [SparklineSeries] = []
        if netInEnabled {
            lines.append(SparklineSeries(
                id: ChartSeries.netIn.rawValue,
                samples: netInHistory,
                color: ChartSeries.netIn.storedTint,
            ))
        }
        if netOutEnabled {
            lines.append(SparklineSeries(
                id: ChartSeries.netOut.rawValue,
                samples: netOutHistory,
                color: ChartSeries.netOut.storedTint,
            ))
        }
        if lines.isEmpty {
            lines.append(SparklineSeries(
                id: "net.in",
                samples: netInHistory,
                color: networkTint,
            ))
        }
        return lines
    }
}
