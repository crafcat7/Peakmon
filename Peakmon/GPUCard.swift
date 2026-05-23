//
//  GPUCard.swift
//  Peakmon
//
//  Dashboard GPU card: model + core count (queried once on first
//  appearance via `GPUCollector.deviceInfo()`), utilization %
//  accessory with optional GPU temperature, and a single-trace
//  sparkline of the device utilization rail.
//

import PeakmonCollectors
import PeakmonCore
import PeakmonUI
import SwiftUI

struct GPUCard: View {
    @Environment(MetricsStore.self) private var store
    @Environment(\.cardSettings) private var cardSettings

    private var tint: Color { cardSettings.tint(.gpu) }
    private var util: Double { store.value(for: .gpuUtilization) }

    /// Static GPU model + core count, populated once on first
    /// appearance from the IORegistry. Cached in `@State` so the
    /// IOKit query only runs once per popover lifetime instead of
    /// on every body pass. Optional so the card stays usable on
    /// machines where the driver does not surface these fields
    /// (e.g. some VMs).
    @State private var gpuInfo: GPUDeviceInfo?

    var body: some View {
        DashboardCardTemplate(
            title: "GPU",
            systemImage: "cpu.fill",
            tint: tint,
            stats: {
                var s = [CardStat(label: "Model", value: gpuInfo?.model ?? "Unknown", tint: tint)]
                if let cores = gpuInfo?.coreCount {
                    s.append(CardStat(label: "Cores", value: "\(cores)", tint: tint))
                }
                return s
            }(),
            accessory: {
                let gpuTemp = store.latest(for: .thermalGPU)?.value
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(util, specifier: "%.0f")%")
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText(value: util))
                        .animation(.smooth, value: util)
                    if let gpuTemp, gpuTemp > 0 {
                        Text("\(Int(gpuTemp.rounded()))°C")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            },
            chart: {
                // The IOAccelerator driver also exposes Renderer and
                // Tiler counters, but on Apple Silicon (TBDR) all
                // three track each other within ~1 %, so only the
                // Device rail is plotted. No per-series toggle —
                // chart always shows the single utilization trace
                // coloured with the card's own tint.
                MetricSparklineView(
                    series: [SparklineSeries(
                        id: "gpu.utilization",
                        samples: store.history(for: .gpuUtilization),
                        color: tint,
                    )],
                    yMin: 0,
                    yMax: 100,
                )
            },
        )
        .onAppear {
            if gpuInfo == nil { gpuInfo = GPUCollector.deviceInfo() }
        }
    }
}
