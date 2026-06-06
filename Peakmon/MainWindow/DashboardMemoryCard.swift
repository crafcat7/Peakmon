//
//  DashboardMemoryCard.swift
//  Peakmon
//
//  Memory panel for the unified dashboard, mirroring
//  `DashboardCPUCard`:
//
//    Headline — used-bytes number, pressure ratio bar + percent,
//               wired / compressed / swap chips, pressure-history
//               sparkline.
//    Detail   — bytes breakdown (wired + compressed + swap + other)
//               that always sums to the headline `used`.
//    Footer   — kernel pressure label (Normal / Warning / Urgent /
//               Critical) + swap.
//
//  Percent tracks pressure, not utilisation: unified memory caches
//  aggressively so "used" sits near 100 % in steady state, whereas
//  pressure is what tells the user to worry — the same metric
//  Activity Monitor's bottom-strip bar uses.
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
                Text(DashboardFormatting.bytesHeadline(used))
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

            // Composition bar: wired first (kernel can't reclaim
            // it), then compressed, then swap, then a remainder slot
            // for the rest of "used" so the bar accounts for the
            // full headline number.
            compositionBar
                .frame(height: 6)
                .padding(.top, 4)

            HStack(spacing: 14) {
                MetricChipView(label: "wired", value: DashboardFormatting.bytesShort(wired), color: .indigo)
                MetricChipView(label: "compressed", value: DashboardFormatting.bytesShort(compressed), color: .purple)
                if swap > 0 {
                    MetricChipView(label: "swap", value: DashboardFormatting.bytesShort(swap), color: .orange)
                }
            }
        }
    }

    /// Stacked bar across the three named regions, as fractions of
    /// `used` (the absolute total is already in the headline) — it
    /// answers "what is the used memory made of".
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

    private var trendChart: some View {
        // Pressure history, not memoryUsed: a flat ~95 % used line
        // says nothing, while a pressure trend shows whether the
        // workload is approaching swap.
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

    /// Sparkline colour follows the pressure band (green → yellow →
    /// red) in lockstep with the accessory percent; stays on the
    /// memory tint at normal pressure so quiet cards look quiet.
    private var pressureTrendColor: Color {
        switch pressureLevel {
        case 2: .yellow
        case 4, 8: .red
        default: tint
        }
    }

    // MARK: - Detail

    /// Breakdown row: wired + compressed + swap + "other" sums to
    /// the headline `used`. Larger than the chip row so the detail
    /// adds information rather than re-printing the same numbers.
    private var byteBreakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Composition")
                .font(.subheadline.weight(.semibold))

            VStack(spacing: 6) {
                breakdownRow(label: "Wired", value: wired, color: .indigo)
                breakdownRow(label: "Compressed", value: compressed, color: .purple)
                breakdownRow(label: "Swap on disk", value: swap, color: .orange)
                let other = max(0, used - wired - compressed - swap)
                breakdownRow(label: "App + cache", value: other, color: tint)
            }
        }
    }

    private func breakdownRow(label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.caption.weight(.medium))
                .frame(width: 110, alignment: .leading)
            Text(DashboardFormatting.bytesShort(value))
                .font(.caption.monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .trailing)
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
                Text(swap > 0 ? DashboardFormatting.bytesShort(swap) : "Idle")
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
}
