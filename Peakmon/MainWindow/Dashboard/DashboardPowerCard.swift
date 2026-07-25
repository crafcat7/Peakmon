//
//  DashboardPowerCard.swift
//  Peakmon
//
//  Power panel for the unified dashboard. Battery facts ride in
//  the footer on laptops, separated by the shared footer divider
//  so the main Power body stays focused on watts.
//
//    Summary   — dominant total package watts.
//    Detail    — per-rail decomposition (CPU + GPU + DRAM + Display)
//                as horizontal bars.
//    Footer    — battery level / source / health / cycles on the
//                left, with battery temperature anchored bottom-right.
//

import PeakmonCore
import PeakmonUI
import SwiftUI

struct DashboardPowerCard: View {
    @Environment(MetricsStore.self) private var store
    @Environment(\.cardSettings) private var cardSettings

    private var tint: Color { cardSettings.tint(.power) }

    private var powerCPU: Double { store.value(for: .powerCPU) }
    private var powerGPU: Double { store.value(for: .powerGPU) }
    private var powerDRAM: Double { store.value(for: .powerDRAM) }
    private var powerDisplay: Double { store.value(for: .powerDisplay) }
    /// Prefer kernel-reported system watts (includes losses); fall
    /// back to package watts. Same fallback as the popover PowerCard
    /// so the two views agree on the headline.
    private var totalWatts: Double {
        let system = store.latest(for: .powerSystem)?.value ?? 0
        return system > 0 ? system : store.value(for: .powerPackage)
    }

    // Battery is optional — desktops surface none and IOPMU returns
    // nil. Any missing field collapses the whole battery sub-block.
    private var batteryLevel: Double? { store.latest(for: .batteryLevel)?.value }
    private var batteryCycleCount: Int? {
        return store.latest(for: .batteryCycleCount).map { Int($0.value) }
    }
    private var batteryHealth: Double? { store.latest(for: .batteryHealth)?.value }
    private var batteryTemperature: Double? { store.latest(for: .batteryTemperature)?.value }
    /// 0 = battery, 1 = AC. Stored as a numeric metric to fit the
    /// metrics-store value model.
    private var isOnBattery: Bool? {
        return store.latest(for: .batteryPowerSource).map { $0.value < 0.5 }
    }
    private var hasBattery: Bool { batteryLevel != nil }

    var body: some View {
        DashboardMetricCard(
            title: "Power",
            systemImage: "bolt.fill",
            tint: tint,
            showsFooter: hasBattery,
            showsFooterDivider: false,
            isEmphasized: true,
            headline: { summary },
            detail: { expandedDetail },
            footer: { batteryFooter },
        )
    }

    // MARK: - Collapsed

    private var summary: some View {
        VStack(alignment: .leading, spacing: dashboardSummarySpacing) {
            HStack(alignment: .firstTextBaseline, spacing: dashboardHeadlineUnitSpacing) {
                Text(String(format: "%.1f", totalWatts))
                    .font(.system(size: dashboardHeadlineNumberSize, weight: .bold, design: .rounded).monospacedDigit())
                Text("W")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

        }
    }

    // MARK: - Expanded

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            railBreakdown
        }
        .padding(.top, dashboardDetailTopPadding)
    }

    private var railBreakdown: some View {
        let maxRail = max(0.5, [powerCPU, powerGPU, powerDRAM, powerDisplay].max() ?? 0.5)
        return VStack(alignment: .leading, spacing: 5) {
            DashboardSectionLabel(title: "Rails")

            VStack(spacing: 4) {
                LabeledBarRow(label: "CPU", value: DashboardFormatting.wattsRail(powerCPU), fraction: powerCPU / maxRail, color: .blue)
                LabeledBarRow(label: "GPU", value: DashboardFormatting.wattsRail(powerGPU), fraction: powerGPU / maxRail, color: .indigo)
                LabeledBarRow(label: "DRAM", value: DashboardFormatting.wattsRail(powerDRAM), fraction: powerDRAM / maxRail, color: .pink)
                LabeledBarRow(label: "Display", value: DashboardFormatting.wattsRail(powerDisplay), fraction: powerDisplay / maxRail, color: .teal)
            }
        }
    }

    // Level / source / health / cycles — the state and lifetime facts
    // not shown by the headline watts. IOKit's
    // `TimeRemaining` / `TimeToFullCharge` are omitted: the field is
    // unreliable across device classes and "Remaining" means
    // different things depending on `IsCharging`.
    private var batteryFooter: some View {
        HStack(alignment: .top, spacing: 20) {
            HStack(alignment: .top, spacing: 18) {
                statBlock(title: "Level", value: batteryLevel.map { String(format: "%.0f%%", $0) } ?? "—",
                          tint: batteryLevelTint)
                statBlock(title: "Source", value: sourceLabel,
                          tint: isOnBattery == true ? .yellow : .green)
                statBlock(title: "Health", value: batteryHealth.map { String(format: "%.0f%%", $0) } ?? "—",
                          tint: healthTint)
                statBlock(title: "Cycles", value: batteryCycleCount.map { String($0) } ?? "—",
                          tint: .secondary)
            }

            Spacer(minLength: 16)

            temperatureFooter
        }
    }

    private func statBlock(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(tint)
        }
    }

    private var temperatureFooter: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("Temp")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Image(systemName: "thermometer.medium")
                    .font(.caption)
                    .foregroundStyle(batteryTemperatureTint)
                Text(batteryTemperatureLabel)
                    .font(.callout.monospacedDigit().weight(.medium))
                    .foregroundStyle(batteryTemperatureTint)
            }
        }
    }

    private var batteryLevelTint: Color {
        guard let level = batteryLevel else { return .secondary }
        if level < 20 { return .red }
        if level < 40 { return .orange }
        return .green
    }

    private var healthTint: Color {
        guard let health = batteryHealth else { return .secondary }
        if health < 80 { return .red }
        if health < 90 { return .orange }
        return .green
    }

    private var batteryTemperatureLabel: String {
        guard let temperature = batteryTemperature else { return "—" }
        return "\(Int(temperature.rounded()))°C"
    }

    private var batteryTemperatureTint: Color {
        guard let temperature = batteryTemperature else { return .secondary }
        return DashboardFormatting.batteryTemperatureColor(temperature)
    }

    private var sourceLabel: String {
        switch isOnBattery {
        case true?: "Battery"
        case false?: "AC"
        case nil: "—"
        }
    }

}
