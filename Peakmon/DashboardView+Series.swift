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

    /// GPU sparkline payload. Mirrors the CPU card: defaults hide the
    /// "Device" line because the headline percentage is already shown
    /// in the card accessory, leaving Renderer + Tiler to drive the
    /// chart. Falls back to the Device series so the chart never goes
    /// blank if the user disables every series.
    var gpuSparklineSeries: [SparklineSeries] {
        var lines: [SparklineSeries] = []
        if gpuDeviceEnabled {
            lines.append(SparklineSeries(
                id: ChartSeries.gpuDevice.rawValue,
                samples: gpuUtilHistory,
                color: ChartSeries.gpuDevice.storedTint,
            ))
        }
        if gpuRendererEnabled {
            lines.append(SparklineSeries(
                id: ChartSeries.gpuRenderer.rawValue,
                samples: gpuRendererHistory,
                color: ChartSeries.gpuRenderer.storedTint,
            ))
        }
        if gpuTilerEnabled {
            lines.append(SparklineSeries(
                id: ChartSeries.gpuTiler.rawValue,
                samples: gpuTilerHistory,
                color: ChartSeries.gpuTiler.storedTint,
            ))
        }
        if lines.isEmpty {
            lines.append(SparklineSeries(
                id: "gpu.utilization",
                samples: gpuUtilHistory,
                color: gpuTint,
            ))
        }
        return lines
    }

    /// Power sparkline payload. Overlays whichever of the four
    /// sub-rails (CPU / GPU / ANE / DRAM) the user has enabled.
    /// Falls back to the CPU rail so the chart never goes blank.
    var powerSparklineSeries: [SparklineSeries] {
        var lines: [SparklineSeries] = []
        if powerCPUEnabled {
            lines.append(SparklineSeries(
                id: ChartSeries.powerCPU.rawValue,
                samples: powerCPUHistory,
                color: ChartSeries.powerCPU.storedTint,
            ))
        }
        if powerGPUEnabled {
            lines.append(SparklineSeries(
                id: ChartSeries.powerGPU.rawValue,
                samples: powerGPUHistory,
                color: ChartSeries.powerGPU.storedTint,
            ))
        }
        if powerDRAMEnabled {
            lines.append(SparklineSeries(
                id: ChartSeries.powerDRAM.rawValue,
                samples: powerDRAMHistory,
                color: ChartSeries.powerDRAM.storedTint,
            ))
        }
        if lines.isEmpty {
            lines.append(SparklineSeries(
                id: "power.cpu",
                samples: powerCPUHistory,
                color: powerTint,
            ))
        }
        return lines
    }
}
