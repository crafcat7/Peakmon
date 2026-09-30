//
//  DashboardMemoryCard.swift
//  Peakmon
//
//  Memory panel for the unified dashboard, mirroring
//  `DashboardCPUCard`:
//
//    Headline — used bytes and used percentage, followed by the
//               discrete kernel pressure state.
//    Detail   — physical-memory composition that sums to `used`,
//               with disk-backed swap shown separately.
//
//  Used percentage and kernel pressure are different signals. The
//  percentage describes occupancy; the pressure state tells the user
//  whether the kernel is struggling to satisfy memory demand.
//

import PeakmonCore
import PeakmonUI
import SwiftUI

struct DashboardMemoryCard: View {
    @Environment(MetricsStore.self) private var store
    @Environment(\.cardSettings) private var cardSettings

    private var tint: Color { cardSettings.tint(.memory) }

    private var used: Double { store.value(for: .memoryUsed) }
    private var usedPercent: Double { store.value(for: .memoryUsedPercent) }
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
                Text(String(format: "%.0f%%", usedPercent))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(pressureTint)
                Text("Used")
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

    /// Physical-memory composition. Swap is disk-backed and therefore
    /// stays outside the values that sum to the `used` headline.
    private var byteBreakdown: some View {
        VStack(alignment: .leading, spacing: 6) {
            DashboardSectionLabel(title: "Composition")

            VStack(spacing: 5) {
                breakdownRow(label: "Wired", value: wired, color: .indigo)
                breakdownRow(label: "Compressed", value: compressed, color: .purple)
                let other = max(0, used - wired - compressed)
                breakdownRow(label: "App + cache", value: other, color: tint)
            }
            if swap > 0 {
                breakdownRow(label: "Swap on disk", value: swap, color: .orange)
                    .padding(.top, 3)
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
