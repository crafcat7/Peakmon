//
//  DashboardDiskCard.swift
//  Peakmon
//
//  Disk panel using the shared `DashboardMetricCard` chrome.
//
//  No per-volume / per-process drill-down: `IOBlockStorageDriver`
//  aggregates at the device, not the filesystem, level, and
//  per-process I/O needs entitlements ad-hoc signing can't grant.
//  So the card shows total R/W throughput, a single dual-line trend,
//  and root-volume capacity — every fact the metrics tier exposes
//  without repeating the same current-rate numbers.
//

import PeakmonCore
import PeakmonUI
import SwiftUI

struct DashboardDiskCard: View {
    @Environment(MetricsStore.self) private var store
    @Environment(\.cardSettings) private var cardSettings

    private var tint: Color { cardSettings.tint(.disk) }

    private var read: Double { store.value(for: .diskReadRate) }
    private var write: Double { store.value(for: .diskWriteRate) }
    private var throughputTotal: Double { max(0, read + write) }
    private var diskUsed: Double { store.value(for: .diskUsed) }
    private var diskTotal: Double { store.value(for: .diskTotal) }

    var body: some View {
        DashboardMetricCard(
            title: "Disk",
            systemImage: "internaldrive",
            tint: tint,
            minHeight: dashboardRateCardMinHeight,
            headline: { headlineRow },
            detail: { detail },
            footer: { EmptyView() },
        )
    }

    private var headlineRow: some View {
        HStack(alignment: .top, spacing: 20) {
            summary
                .frame(maxWidth: .infinity, alignment: .leading)
            trendChart
                .frame(width: 200, height: dashboardRateTrendChartHeight)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(DashboardFormatting.rateHeadline(throughputTotal))
                    .font(.system(size: 32, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text("Total")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)

            Text("Throughput")
                .font(.caption)
                .foregroundStyle(.secondary)

            throughputChips
        }
    }

    private var throughputChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            MetricChipView(label: "read", value: DashboardFormatting.rateShort(read), color: .blue, arrow: "arrow.down")
            MetricChipView(label: "write", value: DashboardFormatting.rateShort(write), color: .orange, arrow: "arrow.up")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trendChart: some View {
        MetricSparklineView(series: [
            SparklineSeries(
                id: "disk.read",
                samples: store.historySuffix(for: .diskReadRate, limit: dashboardRateSparklineSampleLimit),
                color: .blue,
            ),
            SparklineSeries(
                id: "disk.write",
                samples: store.historySuffix(for: .diskWriteRate, limit: dashboardRateSparklineSampleLimit),
                color: .orange,
            ),
        ])
    }

    // MARK: - Detail

    /// Mirrors the Network card with a single fixed-height summary
    /// block. Current read/write rates stay in the headline chips so
    /// the detail area can carry a different dimension: capacity.
    private var detail: some View {
        DashboardRateBalanceDetail(
            balance: DashboardRateBalance(
                title: "Boot volume",
                trailing: String(format: "%.0f%%", ratio * 100),
                fraction: ratio,
                primaryLabel: "Used",
                primaryValue: DashboardFormatting.bytesShort(diskUsed),
                primaryColor: usageTint(ratio),
                secondaryLabel: "Free",
                secondaryValue: DashboardFormatting.bytesShort(max(diskTotal - diskUsed, 0)),
                secondaryColor: .secondary,
            ),
        )
    }

    private var ratio: Double {
        diskTotal > 0 ? diskUsed / diskTotal : 0
    }

    private func usageTint(_ ratio: Double) -> Color {
        if ratio < 0.8 { return tint }
        if ratio < 0.9 { return .yellow }
        return .red
    }

}
