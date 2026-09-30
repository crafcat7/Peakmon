//
//  DashboardPowerCard.swift
//  Peakmon
//
//  Power panel for the unified dashboard. Battery facts ride in
//  the footer on laptops, separated by the shared footer divider
//  so the main Power body stays focused on watts.
//
//    Summary   — whole-system or SoC-package watts, with scope labeled.
//    Detail    — available Energy Model or SMC supply rails, with each
//                fallback scope labeled instead of combining sources.
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
    private let liveMaximumAge: TimeInterval = 8

    private var cpuSample: MetricSample? {
        store.latest(for: .powerCPU, maximumAge: liveMaximumAge)
            ?? store.latest(for: .powerCPUSupply, maximumAge: liveMaximumAge)
    }
    private var powerCPU: Double? { cpuSample?.value }
    private var cpuLabel: String { cpuSample?.kind == .powerCPUSupply ? "CPU supply" : "CPU" }
    private var powerGPU: Double? { store.latest(for: .powerGPU, maximumAge: liveMaximumAge)?.value }
    private var memorySample: MetricSample? {
        store.latest(for: .powerDRAM, maximumAge: liveMaximumAge)
            ?? store.latest(for: .powerDRAMSupply, maximumAge: liveMaximumAge)
    }
    private var displaySample: MetricSample? {
        store.latest(for: .powerDisplay, maximumAge: liveMaximumAge)
            ?? store.latest(for: .powerDisplayBacklight, maximumAge: liveMaximumAge)
    }
    private var powerDRAM: Double? { memorySample?.value }
    private var powerDisplay: Double? { displaySample?.value }
    private var memoryLabel: String { memorySample?.kind == .powerDRAMSupply ? "DRAM supply" : "DRAM" }
    private var displayLabel: String { displaySample?.kind == .powerDisplayBacklight ? "Backlight" : "Display" }
    private var headlineSample: MetricSample? {
        store.latest(for: .powerSystem, maximumAge: liveMaximumAge)
            ?? store.latest(for: .powerPackage, maximumAge: liveMaximumAge)
    }
    private var totalWatts: Double? { headlineSample?.value }
    private var headlineScope: String? {
        switch headlineSample?.kind {
        case .powerSystem: "System"
        case .powerPackage: "SoC package"
        default: nil
        }
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
                Text(totalWatts.map { String(format: "%.1f", $0) } ?? "—")
                    .font(.system(size: dashboardHeadlineNumberSize, weight: .bold, design: .rounded).monospacedDigit())
                if totalWatts != nil {
                    Text("W")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if let headlineScope {
                Text(LocalizedStringKey(headlineScope))
                    .font(.caption)
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
        let maxRail = max(0.5, [powerCPU, powerGPU, powerDRAM, powerDisplay].compactMap { $0 }.max() ?? 0.5)
        return VStack(alignment: .leading, spacing: 5) {
            DashboardSectionLabel(title: "Rails")

            VStack(spacing: 4) {
                LabeledBarRow(label: cpuLabel, value: powerCPU.map(DashboardFormatting.wattsRail) ?? "—", fraction: (powerCPU ?? 0) / maxRail, color: .blue, labelWidth: 80)
                    .help(cpuSample?.kind == .powerCPUSupply
                          ? "CPU supply power averaged across the current sampling window."
                          : "CPU energy-model power averaged across the current sampling window.")
                LabeledBarRow(label: "GPU", value: powerGPU.map(DashboardFormatting.wattsRail) ?? "—", fraction: (powerGPU ?? 0) / maxRail, color: .indigo, labelWidth: 80)
                    .help("GPU energy-model power; its measurement scope differs from the GPU supply rails.")
                LabeledBarRow(label: memoryLabel, value: powerDRAM.map(DashboardFormatting.wattsRail) ?? "—", fraction: (powerDRAM ?? 0) / maxRail, color: .pink, labelWidth: 80)
                    .help(memorySample?.kind == .powerDRAMSupply
                          ? "DRAM supply power; excludes the memory controller and fabric."
                          : "Memory, controller and fabric energy-model power.")
                LabeledBarRow(label: displayLabel, value: powerDisplay.map(DashboardFormatting.wattsRail) ?? "—", fraction: (powerDisplay ?? 0) / maxRail, color: .teal, labelWidth: 80)
                    .help(displaySample?.kind == .powerDisplayBacklight
                          ? "Built-in display backlight supply only; excludes display engines and external monitors."
                          : "Internal and external display-engine energy-model power.")
            }
        }
        .help("These readings have different measurement scopes and do not add up to whole-system power.")
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
                    .help("Capacity-based estimate; may differ from macOS Battery Health.")
                statBlock(title: "Cycles", value: batteryCycleCount.map { String($0) } ?? "—",
                          tint: .secondary)
            }

            Spacer(minLength: 16)

            temperatureFooter
        }
    }

    private func statBlock(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(title))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(tint)
        }
    }

    private func statBlock(title: String, value: LocalizedStringKey, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(title))
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

    private var sourceLabel: LocalizedStringKey {
        switch isOnBattery {
        case true?: "Battery"
        case false?: "AC"
        case nil: "—"
        }
    }

}
