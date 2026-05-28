//
//  DashboardPowerCard.swift
//  Peakmon
//
//  Power + battery panel for the unified dashboard. Battery is
//  intentionally folded into Power rather than getting its own
//  card — on a desktop Mac there's no battery, and on a laptop
//  the user almost always wants to see "what's drawing watts"
//  and "how long do I have" in the same glance.
//
//    Collapsed — total package watts headline + CPU/GPU/DRAM/
//                Display breakdown chips + dual sparkline (CPU
//                blue, GPU indigo).
//    Expanded  — stacked package decomposition (CPU + GPU + DRAM
//                + Display = system watts) with each rail as a
//                horizontal bar and absolute watts label.
//                Battery sub-block when present: level, cycle
//                count, health %, time remaining, source.
//    Footer    — total system watts + battery status chip.
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
    /// Prefer the kernel-reported system watts when available
    /// (it includes losses); fall back to package watts (CPU
    /// die-level) otherwise. Same fallback the popover PowerCard
    /// uses, so the two views agree on the headline number.
    private var totalWatts: Double {
        let system = store.latest(for: .powerSystem)?.value ?? 0
        return system > 0 ? system : store.value(for: .powerPackage)
    }

    // Battery data is optional — Mac desktops surface no battery
    // at all and IOPMU returns nil. We treat any missing field as
    // "no battery" and collapse the entire battery sub-block.
    private var batteryLevel: Double? { store.latest(for: .batteryLevel)?.value }
    private var batteryCycleCount: Int? {
        store.latest(for: .batteryCycleCount).map { Int($0.value) }
    }
    private var batteryHealth: Double? { store.latest(for: .batteryHealth)?.value }
    /// 0 = battery, 1 = AC. Stored as a numeric metric to fit the
    /// metrics-store value model.
    private var isOnBattery: Bool? {
        store.latest(for: .batteryPowerSource).map { $0.value < 0.5 }
    }
    private var hasBattery: Bool { batteryLevel != nil }

    var body: some View {
        DashboardMetricCard(
            title: "Power",
            systemImage: "bolt.fill",
            tint: tint,
            headline: { headlineRow },
            detail: { expandedDetail },
            footer: { systemFooter },
        )
    }

    private var headlineRow: some View {
        HStack(alignment: .top, spacing: 20) {
            summary
                .frame(maxWidth: .infinity, alignment: .leading)
            trendChart
                .frame(width: 200, height: 110)
        }
    }

    // MARK: - Collapsed

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.1f", totalWatts))
                    .font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(value: totalWatts))
                    .animation(.smooth, value: totalWatts)
                Text("W")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text("System draw")
                .font(.caption)
                .foregroundStyle(.secondary)

            decompositionBar
                .frame(height: 6)
                .padding(.top, 4)

            HStack(spacing: 12) {
                wattChip(label: "CPU", watts: powerCPU, color: .blue)
                wattChip(label: "GPU", watts: powerGPU, color: .indigo)
                wattChip(label: "DRAM", watts: powerDRAM, color: .pink)
            }
        }
    }

    /// CPU + GPU + DRAM + Display = (roughly) package watts.
    /// Slots that read zero contribute nothing to the bar so a
    /// desktop with no Display rail doesn't show an empty wedge.
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

    private func wattChip(label: String, watts: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(format: "%.1f W", watts))
                .font(.caption.monospacedDigit().weight(.medium))
        }
    }

    private var trendChart: some View {
        // CPU + GPU power overlay — the two rails the user can
        // actually do something about. DRAM and Display tend to
        // be small constants, so they live in the chip row, not
        // the spark.
        MetricSparklineView(series: [
            SparklineSeries(
                id: "power.cpu",
                samples: store.history(for: .powerCPU),
                color: .blue,
            ),
            SparklineSeries(
                id: "power.gpu",
                samples: store.history(for: .powerGPU),
                color: .indigo,
            ),
        ])
    }

    // MARK: - Expanded

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            railBreakdown
            if hasBattery {
                batteryBlock
            }
        }
    }

    private var railBreakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rails")
                .font(.subheadline.weight(.semibold))

            VStack(spacing: 6) {
                railRow(label: "CPU", watts: powerCPU, color: .blue)
                railRow(label: "GPU", watts: powerGPU, color: .indigo)
                railRow(label: "DRAM", watts: powerDRAM, color: .pink)
                railRow(label: "Display", watts: powerDisplay, color: .teal)
            }
        }
    }

    private func railRow(label: String, watts: Double, color: Color) -> some View {
        // Bar scales against the largest rail rather than total
        // system watts so a 0.4 W DRAM line is still visible
        // next to a 25 W CPU spike.
        let maxRail = max(0.5, [powerCPU, powerGPU, powerDRAM, powerDisplay].max() ?? 0.5)
        return HStack(spacing: 10) {
            Text(label)
                .font(.caption.weight(.medium))
                .frame(width: 70, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.18))
                    Capsule()
                        .fill(color)
                        .frame(width: proxy.size.width * (watts / maxRail))
                }
            }
            .frame(height: 6)
            Text(String(format: "%.2f W", watts))
                .font(.caption.monospacedDigit())
                .frame(width: 72, alignment: .trailing)
        }
    }

    private var batteryBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Battery")
                .font(.subheadline.weight(.semibold))

            // Two-by-two stat grid — the three lifetime / state
            // facts that don't appear elsewhere on the card:
            //   - source (right now)
            //   - health (lifetime)
            //   - cycles (lifetime)
            //
            // Battery `Level` is intentionally omitted here — it's
            // already shown in the footer's "Battery" stat (with
            // an icon and tint) so duplicating it inside the
            // section just costs horizontal space.
            //
            // We also intentionally omit IOKit's `TimeRemaining` /
            // `TimeToFullCharge`. The field is unreliable across
            // device classes — desktops surface no value, freshly
            // unplugged or thermally-throttled batteries report
            // `0xFFFF` for minutes at a time, and the same
            // "Remaining" label means two completely different
            // things depending on `IsCharging`. Users who need
            // that estimate already have it in the menu-bar
            // battery icon and System Settings.
            HStack(spacing: 24) {
                statBlock(title: "Source", value: sourceLabel,
                          tint: isOnBattery == true ? .yellow : .green)
                statBlock(title: "Health", value: batteryHealth.map { String(format: "%.0f%%", $0) } ?? "—",
                          tint: healthTint)
                statBlock(title: "Cycles", value: batteryCycleCount.map { String($0) } ?? "—",
                          tint: .secondary)
            }
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

    private var sourceLabel: String {
        switch isOnBattery {
        case true?: "Battery"
        case false?: "AC"
        case nil: "—"
        }
    }

    // MARK: - Footer

    private var systemFooter: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f W", totalWatts))
                    .font(.callout.monospacedDigit().weight(.medium))
                    .foregroundStyle(tint)
            }

            if hasBattery {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Battery")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Image(systemName: isOnBattery == true ? "battery.50" : "powerplug.fill")
                            .font(.caption)
                            .foregroundStyle(batteryLevelTint)
                        Text(batteryLevel.map { String(format: "%.0f%%", $0) } ?? "—")
                            .font(.callout.monospacedDigit().weight(.medium))
                    }
                }
            }

            Spacer()
        }
    }
}
