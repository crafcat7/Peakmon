//
//  DashboardGPUCard.swift
//  Peakmon
//
//  GPU panel for the unified dashboard.
//
//    Summary   — dominant utilisation + current utilisation bar.
//    Detail    — Core / CS / SRAM power rails without a redundant
//                section heading.
//    Footer    — total GPU power + temperature without a separator.
//
//  No per-engine breakdown (3D / Media / Compute): macOS exposes
//  it only via private IOReport channels needing Screen Recording
//  entitlement or root + tcc bypass — both out of scope for an
//  ad-hoc signed app. The card keeps the practical questions visible:
//  busy in the headline, drawing watts in the footer, and hot in
//  the bottom-right temperature accessory.
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
            showsFooterDivider: false,
            isEmphasized: true,
            headline: { summary },
            detail: {
                if hasGPUSubRails {
                    gpuSubRails
                }
            },
            footer: { tripletFooter },
        )
    }

    // MARK: - Collapsed

    private var summary: some View {
        VStack(alignment: .leading, spacing: dashboardSummarySpacing) {
            HStack(alignment: .firstTextBaseline, spacing: dashboardHeadlineUnitSpacing) {
                Text(String(format: "%.1f", util))
                    .font(.system(size: dashboardHeadlineNumberSize, weight: .bold, design: .rounded).monospacedDigit())
                Text("%")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ProportionalBarView(fraction: min(1, util / 100), color: tint)
                .padding(.top, dashboardMetricBarTopPadding)

            if let gpuMemInUse {
                MetricChipView(label: "memory", value: DashboardFormatting.bytesShort(gpuMemInUse), color: .cyan)
            }
        }
    }

    // MARK: - Power rails

    /// Keep the Core / command-streamer / SRAM data visible while
    /// omitting the redundant "Power rails" heading. Zero-valued
    /// channels remain useful because they make unavailable or idle
    /// sub-rails explicit instead of changing the card's structure.
    private var hasGPUSubRails: Bool {
        gpuCorePower > 0 || gpuCSPower > 0 || gpuSRAMPower > 0
    }

    private var gpuSubRails: some View {
        let maxSub = max(0.01, [gpuCorePower, gpuCSPower, gpuSRAMPower].max() ?? 0.01)
        return VStack(alignment: .leading, spacing: 6) {
            LabeledBarRow(
                label: "Core",
                value: DashboardFormatting.wattsRail(gpuCorePower),
                fraction: gpuCorePower / maxSub,
                color: .yellow,
                labelWidth: 50,
                valueWidth: 60,
            )
            LabeledBarRow(
                label: "CS",
                value: DashboardFormatting.wattsRail(gpuCSPower),
                fraction: gpuCSPower / maxSub,
                color: .yellow.opacity(0.7),
                labelWidth: 50,
                valueWidth: 60,
            )
            LabeledBarRow(
                label: "SRAM",
                value: DashboardFormatting.wattsRail(gpuSRAMPower),
                fraction: gpuSRAMPower / maxSub,
                color: .yellow.opacity(0.5),
                labelWidth: 50,
                valueWidth: 60,
            )
        }
        .padding(.top, dashboardDetailTopPadding)
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
