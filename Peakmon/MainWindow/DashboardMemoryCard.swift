//
//  DashboardMemoryCard.swift
//  Peakmon
//
//  Memory panel for the unified dashboard. Mirrors the structure
//  of `DashboardCPUCard`:
//
//    Collapsed — large used-bytes headline, pressure ratio bar
//                + accessory percent, wired / compressed / swap
//                chips, trend sparkline driven by pressure
//                history.
//    Expanded  — top-N processes by RSS (the same data the popover
//                ProcessesCard uses, re-sorted by `memoryBytes`),
//                plus a bytes-breakdown row that always sums to
//                the system total so the user can sanity-check
//                where their RAM actually went.
//    Footer    — kernel pressure label (Normal / Warning / Urgent
//                / Critical) — the most decision-actionable single
//                fact about memory pressure on macOS.
//
//  Why pressure rather than utilisation for the percent: macOS
//  reports near-100% RAM "used" in steady-state because the
//  unified memory architecture aggressively caches; pressure is
//  the number that actually tells the user whether to be
//  worried, and it's the same metric Activity Monitor's bar in
//  the bottom strip uses.
//

import PeakmonCore
import PeakmonUI
import SwiftUI

struct DashboardMemoryCard: View {
    @Environment(MetricsStore.self) private var store
    @Environment(\.cardSettings) private var cardSettings

    private var tint: Color { cardSettings.tint(.memory) }

    private var used: Double { store.value(for: .memoryUsed) }
    private var pressure: Double { store.value(for: .memoryPressure) }
    private var wired: Double { store.value(for: .memoryWired) }
    private var compressed: Double { store.value(for: .memoryCompressed) }
    private var swap: Double { store.value(for: .memorySwapUsed) }

    /// Discrete kernel VM pressure band (1 normal / 2 warning /
    /// 4 urgent / 8 critical). `nil` until the first sample.
    private var pressureLevel: Int? {
        store.latest(for: .memoryPressureLevel).map { Int($0.value) }
    }

    private var pressureTint: Color {
        switch pressureLevel {
        case 2: .yellow
        case 4, 8: .red
        default: .primary
        }
    }

    private var pressureLabel: String {
        switch pressureLevel {
        case 2: "Warning"
        case 4: "Urgent"
        case 8: "Critical"
        default: "Normal"
        }
    }

    var body: some View {
        DashboardMetricCard(
            title: "Memory",
            systemImage: "memorychip",
            tint: tint,
            headline: { headlineRow },
            detail: { byteBreakdown },
            footer: { pressureFooter },
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
                Text(formatBytesHeadline(used))
                    .font(.system(size: 32, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(value: used))
                    .animation(.smooth, value: used)
                Text("used")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Text(String(format: "%.0f%%", pressure))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(pressureTint)
                Text("pressure · \(pressureLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Composition bar. Wired sits on the left because the
            // kernel cannot reclaim it, then compressed, then swap.
            // The remainder slot represents "everything else in
            // 'used'" so the bar visually accounts for the full
            // headline number rather than leaving an unexplained
            // gap.
            compositionBar
                .frame(height: 6)
                .padding(.top, 4)

            HStack(spacing: 14) {
                metricChip(label: "wired", value: wired, color: .indigo)
                metricChip(label: "compressed", value: compressed, color: .purple)
                if swap > 0 {
                    metricChip(label: "swap", value: swap, color: .orange)
                }
            }
        }
    }

    /// Stacked bar across the three named regions. Widths are
    /// expressed as fractions of `used` rather than total RAM —
    /// the user already saw the absolute number above, this bar
    /// answers "what is the composition of the used bytes".
    private var compositionBar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let denom = max(used, 1)
            let wiredW = width * (wired / denom)
            let compressedW = width * (compressed / denom)
            let swapW = width * (swap / denom)
            let otherW = max(0, width - wiredW - compressedW - swapW)

            HStack(spacing: 0) {
                Rectangle().fill(Color.indigo).frame(width: wiredW)
                Rectangle().fill(Color.purple).frame(width: compressedW)
                Rectangle().fill(Color.orange).frame(width: swapW)
                Rectangle().fill(tint.opacity(0.6)).frame(width: otherW)
            }
            .clipShape(.capsule)
        }
    }

    private func metricChip(label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(formatBytesShort(value))
                .font(.caption.monospacedDigit().weight(.medium))
        }
    }

    private var trendChart: some View {
        // Pressure history rather than memoryUsed: a flat 95%
        // utilisation line says nothing, whereas a pressure trend
        // tells the user whether their workload is approaching
        // swap territory.
        MetricSparklineView(
            samples: store.history(for: .memoryPressure),
            style: SparklineStyle(
                color: pressureTrendColor,
                fillOpacity: 0.18,
                lineWidth: 1.5,
                yMin: 0,
                yMax: 100,
            ),
        )
    }

    /// Sparkline colour follows the pressure band so an escalating
    /// trace switches green → yellow → red in lockstep with the
    /// accessory percent. Stays on the user's memory tint during
    /// normal pressure so quiet cards look quiet.
    private var pressureTrendColor: Color {
        switch pressureLevel {
        case 2: .yellow
        case 4, 8: .red
        default: tint
        }
    }

    // MARK: - Detail

    /// Always-true breakdown row: wired + compressed + swap +
    /// "other" sums to the headline `used` value. Sized larger
    /// than the chip row above so the drill-down adds genuine
    /// information rather than re-printing the same numbers.
    private var byteBreakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Composition")
                .font(.subheadline.weight(.semibold))

            VStack(spacing: 6) {
                breakdownRow(label: "Wired", value: wired, color: .indigo, hint: "Cannot be paged out")
                breakdownRow(label: "Compressed", value: compressed, color: .purple, hint: "Squeezed by the VM")
                breakdownRow(label: "Swap on disk", value: swap, color: .orange, hint: swap > 0 ? "Paged to disk" : "None")
                let other = max(0, used - wired - compressed - swap)
                breakdownRow(label: "App + cache", value: other, color: tint, hint: "Active app pages and file cache")
            }
        }
    }

    private func breakdownRow(label: String, value: Double, color: Color, hint: String) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.caption.weight(.medium))
                .frame(width: 110, alignment: .leading)
            Text(formatBytesShort(value))
                .font(.caption.monospacedDigit())
                .frame(width: 80, alignment: .trailing)
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Footer

    private var pressureFooter: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Pressure")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: pressureIcon)
                        .font(.caption)
                        .foregroundStyle(pressureTint)
                    Text(pressureLabel)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(pressureTint)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("Swap")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(swap > 0 ? formatBytesShort(swap) : "Idle")
                    .font(.callout.monospacedDigit().weight(.medium))
                    .foregroundStyle(swap > 0 ? .orange : .secondary)
            }
        }
    }

    private var pressureIcon: String {
        switch pressureLevel {
        case 2: "exclamationmark.triangle.fill"
        case 4, 8: "exclamationmark.octagon.fill"
        default: "checkmark.circle.fill"
        }
    }

    // MARK: - Formatters

    /// Headline format prefers a single-decimal GB number when
    /// the value is large enough to read as a unit; below 1 GB
    /// the dashboard falls back to MB integers. Matches Activity
    /// Monitor's display logic.
    private func formatBytesHeadline(_ bytes: Double) -> String {
        let gb = bytes / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = bytes / 1_048_576
        return String(format: "%.0f MB", mb)
    }

    /// Compact two-letter suffix for chip and breakdown rows
    /// where horizontal space is tight.
    private func formatBytesShort(_ bytes: Double) -> String {
        let gb = bytes / 1_073_741_824
        if gb >= 10 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = bytes / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}
