//
//  DashboardMemoryCard.swift
//  Peakmon
//
//  Memory panel for the unified dashboard, mirroring
//  `DashboardCPUCard`:
//
//    Headline — dominant used-bytes number + pressure state.
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
        return store.latest(for: .memoryPressureLevel).map { Int($0.value) }
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
            isEmphasized: true,
            headline: { summary },
            detail: { byteBreakdown },
        )
    }

    // MARK: - Collapsed

    private var summary: some View {
        VStack(alignment: .leading, spacing: dashboardSummarySpacing) {
            HStack(alignment: .firstTextBaseline, spacing: dashboardHeadlineUnitSpacing) {
                Text(DashboardFormatting.bytesHeadline(used))
                    .font(.system(size: dashboardHeadlineNumberSize, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text("Used")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)

            HStack(spacing: 3) {
                Text(String(format: "%.0f%%", pressure))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(pressureTint)
                Text("Pressure")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(LocalizedStringKey(pressureLabel))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Detail

    /// Breakdown row: wired + compressed + swap + "other" sums to
    /// the headline `used`. Larger than the chip row so the detail
    /// adds information rather than re-printing the same numbers.
    private var byteBreakdown: some View {
        VStack(alignment: .leading, spacing: 6) {
            DashboardSectionLabel(title: "Composition")

            VStack(spacing: 5) {
                breakdownRow(label: "Wired", value: wired, color: .indigo)
                breakdownRow(label: "Compressed", value: compressed, color: .purple)
                if swap > 0 {
                    breakdownRow(label: "Swap", value: swap, color: .orange)
                }
                let other = max(0, used - wired - compressed - swap)
                breakdownRow(label: "App + cache", value: other, color: tint)
            }
        }
        .padding(.top, dashboardDetailTopPadding)
    }

    private func breakdownRow(label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(LocalizedStringKey(label))
                .font(.caption.weight(.medium))
                .frame(width: 92, alignment: .leading)
            Text(DashboardFormatting.bytesShort(value))
                .font(.caption.monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

}
