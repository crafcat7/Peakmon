//
//  DashboardPowerCard.swift
//  Peakmon
//
//  Power panel for the unified dashboard. Battery facts ride in
//  the footer on laptops, separated by the shared footer divider
//  so the main Power body stays focused on watts.
//
//    Collapsed — total package watts + CPU/GPU/DRAM/Display chips +
//                dual sparkline (CPU / GPU).
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
            headline: { headlineRow },
            detail: { expandedDetail },
            footer: { batteryFooter },
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
                Text(String(format: "%.1f", totalWatts))
                    .font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                Text("W")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text("System Draw")
                .font(.caption)
                .foregroundStyle(.secondary)

            decompositionBar
                .frame(height: 6)
                .padding(.top, 4)

            HStack(spacing: 12) {
                MetricChipView(label: "CPU", value: DashboardFormatting.wattsChip(powerCPU), color: .blue)
                MetricChipView(label: "GPU", value: DashboardFormatting.wattsChip(powerGPU), color: .indigo)
                MetricChipView(label: "DRAM", value: DashboardFormatting.wattsChip(powerDRAM), color: .pink)
            }
        }
    }

    /// CPU + GPU + DRAM + Display ≈ package watts. Zero rails
    /// contribute nothing so a desktop's missing Display rail shows
    /// no empty wedge.
    private var decompositionBar: some View {
        GeometryReader { proxy in
            let total = max(0.001, powerCPU + powerGPU + powerDRAM + powerDisplay)
            HStack(spacing: 0) {
                Rectangle().fill(Color.blue).frame(width: proxy.size.width * powerCPU / total)
                Rectangle().fill(Color.indigo).frame(width: proxy.size.width * powerGPU / total)
                Rectangle().fill(Color.pink).frame(width: proxy.size.width * powerDRAM / total)
                Rectangle().fill(Color.teal).frame(width: proxy.size.width * powerDisplay / total)
            }
            .clipShape(.capsule)
        }
    }

    private var trendChart: some View {
        // CPU + GPU only — the rails the user can act on. DRAM and
        // Display are small near-constants, so they stay in the chip
        // row, not the spark.
        MetricSparklineView(series: [
            SparklineSeries(
                id: "power.cpu",
                samples: store.historySuffix(for: .powerCPU, limit: dashboardSparklineSampleLimit),
                color: .blue,
            ),
            SparklineSeries(
                id: "power.gpu",
                samples: store.historySuffix(for: .powerGPU, limit: dashboardSparklineSampleLimit),
                color: .indigo,
            ),
        ])
    }

    // MARK: - Expanded

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            railBreakdown
        }
    }

    private var railBreakdown: some View {
        let maxRail = max(0.5, [powerCPU, powerGPU, powerDRAM, powerDisplay].max() ?? 0.5)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Rails")
                .font(.subheadline.weight(.semibold))

            VStack(spacing: 6) {
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
        HStack(alignment: .top, spacing: 24) {
            HStack(alignment: .top, spacing: 22) {
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
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(tint)
        }
    }

    private var temperatureFooter: some View {
        VStack(alignment: .trailing, spacing: 3) {
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
