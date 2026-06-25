//
//  DashboardGPUCard.swift
//  Peakmon
//
//  GPU panel for the unified dashboard.
//
//    Collapsed — utilisation headline + trend sparkline.
//    Expanded  — power-rail decomposition (Core / CS / SRAM)
//                as horizontal bars when available.
//    Footer    — total power + temperature, matching the CPU card's
//                bottom-right Temp treatment.
//
//  No per-engine breakdown (3D / Media / Compute): macOS exposes
//  it only via private IOReport channels needing Screen Recording
//  entitlement or root + tcc bypass — both out of scope for an
//  ad-hoc signed app. The card keeps the practical questions visible:
//  busy in the headline, drawing watts in chips/footer, and hot in
//  the bottom-right temperature footer.
//

import PeakmonCore
import PeakmonUI
import SwiftUI

struct DashboardGPUCard: View {
    @Environment(MetricsStore.self) private var store
    @Environment(\.cardSettings) private var cardSettings

    private var tint: Color { cardSettings.tint(.gpu) }

    private var util: Double { store.value(for: .gpuUtilization) }
    private var gpuTemp: Double? {
        let value = store.latest(for: .thermalGPU)?.value ?? 0
        return value > 0 ? value : nil
    }
    private var gpuPower: Double? {
        let value = store.latest(for: .powerGPU)?.value ?? 0
        return value > 0 ? value : nil
    }
    private var gpuMemInUse: Double? {
        let value = store.latest(for: .gpuMemoryInUse)?.value ?? 0
        return value > 0 ? value : nil
    }
    private var gpuCorePower: Double { store.value(for: .powerGPUCore) }
    private var gpuCSPower: Double { store.value(for: .powerGPUCommandStreamer) }
    private var gpuSRAMPower: Double { store.value(for: .powerGPUSRAM) }

    var body: some View {
        DashboardMetricCard(
            title: "GPU",
            systemImage: "cpu.fill",
            tint: tint,
            headline: { headlineRow },
            detail: { expandedDetail },
            footer: { tripletFooter },
        )
    }

    private var headlineRow: some View {
        HStack(alignment: .top, spacing: 20) {
            summary
                .frame(maxWidth: .infinity, alignment: .leading)
            trendChart
                .frame(width: 200, height: dashboardHeadlineTrendChartHeight)
        }
    }

    // MARK: - Collapsed

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.1f", util))
                    .font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                Text("%")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text("Utilisation")
                .font(.caption)
                .foregroundStyle(.secondary)

            ProportionalBarView(fraction: min(1, util / 100), color: tint)
                .padding(.top, 4)

            HStack(spacing: 14) {
                if let gpuPower {
                    MetricChipView(label: "power", value: String(format: "%.1f W", gpuPower), color: .yellow)
                }
                if let gpuMemInUse {
                    MetricChipView(label: "mem", value: DashboardFormatting.bytesShort(gpuMemInUse), color: .cyan)
                }
            }
        }
    }

    private var trendChart: some View {
        MetricSparklineView(
            samples: store.historySuffix(for: .gpuUtilization, limit: dashboardSparklineSampleLimit),
            style: SparklineStyle(
                color: tint,
                fillOpacity: 0.18,
                lineWidth: 1.5,
                yMin: 0,
                yMax: 100,
            ),
        )
    }

    // MARK: - Expanded

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasGPUSubRails {
                gpuSubRails
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// GPU sub-rail power decomposition: Core / CS / SRAM as
    /// horizontal bars. Only shown when the IOReport channels
    /// report non-zero values (some SoCs do not expose them).
    private var hasGPUSubRails: Bool {
        gpuCorePower > 0 || gpuCSPower > 0 || gpuSRAMPower > 0
    }

    private var gpuSubRails: some View {
        let maxSub = max(0.01, [gpuCorePower, gpuCSPower, gpuSRAMPower].max() ?? 0.01)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Power rails")
                .font(.subheadline.weight(.semibold))

            LabeledBarRow(label: "Core", value: DashboardFormatting.wattsRail(gpuCorePower), fraction: gpuCorePower / maxSub, color: .yellow, labelWidth: 50, valueWidth: 60)
            LabeledBarRow(label: "CS", value: DashboardFormatting.wattsRail(gpuCSPower), fraction: gpuCSPower / maxSub, color: .yellow.opacity(0.7), labelWidth: 50, valueWidth: 60)
            LabeledBarRow(label: "SRAM", value: DashboardFormatting.wattsRail(gpuSRAMPower), fraction: gpuSRAMPower / maxSub, color: .yellow.opacity(0.5), labelWidth: 50, valueWidth: 60)
        }
    }

    // MARK: - Footer

    private var tripletFooter: some View {
        HStack(alignment: .top, spacing: 24) {
            if let gpuPower {
                FooterStatView(title: "Power", value: String(format: "%.1f W", gpuPower), color: .yellow)
            }

            Spacer()

            if let gpuTemp {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Temp")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Image(systemName: "thermometer.medium")
                            .font(.caption)
                            .foregroundStyle(DashboardFormatting.temperatureColor(gpuTemp))
                        Text("\(Int(gpuTemp.rounded()))°C")
                            .font(.callout.monospacedDigit().weight(.medium))
                            .foregroundStyle(DashboardFormatting.temperatureColor(gpuTemp))
                    }
                }
            }
        }
    }
}
