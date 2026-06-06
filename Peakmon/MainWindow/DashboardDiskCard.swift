//
//  DashboardDiskCard.swift
//  Peakmon
//
//  Disk panel using the shared `DashboardMetricCard` chrome.
//
//  No per-volume / per-process drill-down: `IOBlockStorageDriver`
//  aggregates at the device, not the filesystem, level, and
//  per-process I/O needs entitlements ad-hoc signing can't grant.
//  So the card shows the aggregate R/W rate, a root-volume capacity
//  bar, and per-rate chips — every fact the metrics tier exposes.
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
    private var diskUsed: Double { store.value(for: .diskUsed) }
    private var diskTotal: Double { store.value(for: .diskTotal) }

    var body: some View {
        DashboardMetricCard(
            title: "Disk",
            systemImage: "internaldrive",
            tint: tint,
            headline: { headlineRow },
            detail: { capacityDetail },
            footer: { rateFooter },
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

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(DashboardFormatting.rateHeadline(max(read, write)))
                    .font(.system(size: 32, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(value: max(read, write)))
                    .animation(.smooth, value: max(read, write))
                Text("peak")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text("Read + write throughput")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                MetricChipView(label: "read", value: DashboardFormatting.rateShort(read), color: .blue, arrow: "arrow.down")
                MetricChipView(label: "write", value: DashboardFormatting.rateShort(write), color: .orange, arrow: "arrow.up")
            }
        }
    }

    private var trendChart: some View {
        MetricSparklineView(series: [
            SparklineSeries(
                id: "disk.read",
                samples: store.history(for: .diskReadRate),
                color: .blue,
            ),
            SparklineSeries(
                id: "disk.write",
                samples: store.history(for: .diskWriteRate),
                color: .orange,
            ),
        ])
    }

    // MARK: - Detail (capacity)

    /// Capacity block fills the detail slot so the card matches the
    /// CPU / Memory cards' height. Reads the boot volume via
    /// `.diskUsed` / `.diskTotal` — the volume users mean by "disk".
    private var capacityDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Boot volume")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(DashboardFormatting.bytesShort(diskUsed)) of \(DashboardFormatting.bytesShort(diskTotal))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            usageBar
                .frame(height: 8)

            HStack(spacing: 14) {
                capacityChip(label: "used", value: diskUsed, color: usageTint(ratio))
                capacityChip(label: "free", value: max(diskTotal - diskUsed, 0), color: .secondary)
                Spacer()
                Text(String(format: "%.0f%%", ratio * 100))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(usageTint(ratio))
            }
        }
    }

    private var ratio: Double {
        diskTotal > 0 ? diskUsed / diskTotal : 0
    }

    private var usageBar: some View {
        ProportionalBarView(fraction: ratio, color: usageTint(ratio), height: 8)
    }

    private func usageTint(_ ratio: Double) -> Color {
        if ratio < 0.8 { return tint }
        if ratio < 0.9 { return .yellow }
        return .red
    }

    private func capacityChip(label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(DashboardFormatting.bytesShort(value))
                .font(.caption.monospacedDigit().weight(.medium))
        }
    }

    // MARK: - Footer

    private var rateFooter: some View {
        HStack(spacing: 24) {
            footerSlot(title: "Read", value: read, arrow: "arrow.down", color: .blue)
            footerSlot(title: "Write", value: write, arrow: "arrow.up", color: .orange)
            Spacer()
        }
    }

    private func footerSlot(title: String, value: Double, arrow: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Image(systemName: arrow)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color)
                Text(DashboardFormatting.rateShort(value))
                    .font(.callout.monospacedDigit().weight(.medium))
            }
        }
    }
}
