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
    private var gpuPower: Double? { store.latest(for: .powerGPU)?.value }
    private var gpuMemInUse: Double? {
        let value = store.latest(for: .gpuMemoryInUse)?.value ?? 0
        return value > 0 ? value : nil
    }
    private var gpuCorePower: Double? { store.latest(for: .powerGPUCore)?.value }
    private var gpuCSPower: Double? { store.latest(for: .powerGPUCommandStreamer)?.value }
    private var gpuSRAMPower: Double? { store.latest(for: .powerGPUSRAM)?.value }
    private var gpuClustersPower: Double? { store.latest(for: .powerGPUClusters)?.value }
    private var gpuSharedPower: Double? { store.latest(for: .powerGPUShared)?.value }
    private var hasSupplyRails: Bool { gpuClustersPower != nil || gpuSharedPower != nil }

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
                } else if hasSupplyRails {
                    gpuSupplyRails
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
    /// omitting the redundant "Power rails" heading. Valid zero-valued
    /// channels remain visible; unavailable channels use a dash.
    private var hasGPUSubRails: Bool {
        gpuCorePower != nil || gpuCSPower != nil || gpuSRAMPower != nil
    }

    private var gpuSubRails: some View {
        let maxSub = max(0.01, [gpuCorePower, gpuCSPower, gpuSRAMPower].compactMap { $0 }.max() ?? 0.01)
        return VStack(alignment: .leading, spacing: 6) {
            LabeledBarRow(
                label: "Core",
                value: gpuCorePower.map(DashboardFormatting.wattsRail) ?? "—",
                fraction: (gpuCorePower ?? 0) / maxSub,
                color: .yellow,
                labelWidth: 50,
                valueWidth: 60,
            )
            LabeledBarRow(
                label: "CS",
                value: gpuCSPower.map(DashboardFormatting.wattsRail) ?? "—",
                fraction: (gpuCSPower ?? 0) / maxSub,
                color: .yellow.opacity(0.7),
                labelWidth: 50,
                valueWidth: 60,
            )
            LabeledBarRow(
                label: "SRAM",
                value: gpuSRAMPower.map(DashboardFormatting.wattsRail) ?? "—",
                fraction: (gpuSRAMPower ?? 0) / maxSub,
                color: .yellow.opacity(0.5),
                labelWidth: 50,
                valueWidth: 60,
            )
        }
        .padding(.top, dashboardDetailTopPadding)
    }

    // MARK: - Footer

    /// SMC supply rails have a different scope from the IOReport
    /// Core / CS / SRAM model. Keep their labels and history distinct.
    private var gpuSupplyRails: some View {
        let maximum = max(0.01, [gpuClustersPower, gpuSharedPower].compactMap { $0 }.max() ?? 0.01)
        return VStack(alignment: .leading, spacing: 6) {
            DashboardSectionLabel(title: "Supply power")
            LabeledBarRow(
                label: "Clusters",
                value: gpuClustersPower.map(DashboardFormatting.wattsRail) ?? "—",
                fraction: (gpuClustersPower ?? 0) / maximum,
                color: .yellow,
                labelWidth: 70,
                valueWidth: 60,
            )
            LabeledBarRow(
                label: "Shared",
                value: gpuSharedPower.map(DashboardFormatting.wattsRail) ?? "—",
                fraction: (gpuSharedPower ?? 0) / maximum,
                color: .yellow.opacity(0.7),
                labelWidth: 70,
                valueWidth: 60,
            )
        }
        .padding(.top, dashboardDetailTopPadding)
        .help("GPU cluster and shared-logic supply power. These hardware readings have a different scope and sampling window from the GPU energy model below.")
    }

    private var tripletFooter: some View {
        HStack(alignment: .top, spacing: 24) {
            FooterStatView(title: !hasGPUSubRails && hasSupplyRails ? "Model power" : "Power", value: gpuPower.map { String(format: "%.1f W", $0) } ?? "—", color: .yellow)

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
