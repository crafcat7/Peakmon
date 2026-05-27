//
//  DashboardDiskCard.swift
//  Peakmon
//
//  Disk panel using the shared `DashboardMetricCard` chrome.
//
//  Why no per-volume / per-process drill-down: documented at
//  length in an earlier version of this file — `IOBlockStorage-
//  Driver` aggregates at the device, not the filesystem, level,
//  and per-process I/O requires entitlements that ad-hoc signing
//  cannot grant. So the card surfaces the aggregate R/W rate, a
//  root-volume capacity bar, and per-rate chips — every fact the
//  metrics tier exposes, presented honestly.
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
                Text(formatRateHeadline(max(read, write)))
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
                metricChip(label: "read", value: read, color: .green, arrow: "arrow.down")
                metricChip(label: "write", value: write, color: .orange, arrow: "arrow.up")
            }
        }
    }

    private var trendChart: some View {
        MetricSparklineView(series: [
            SparklineSeries(
                id: "disk.read",
                samples: store.history(for: .diskReadRate),
                color: .green,
            ),
            SparklineSeries(
                id: "disk.write",
                samples: store.history(for: .diskWriteRate),
                color: .orange,
            ),
        ])
    }

    // MARK: - Detail (capacity)

    /// Capacity block fills the detail slot so the card reaches
    /// the same height as the CPU / Memory cards next to it.
    /// Reads the boot volume from the same metrics already
    /// surfaced as `.diskUsed` / `.diskTotal` — the one volume
    /// the user almost always means when they say "disk".
    private var capacityDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Boot volume")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(formatBytesShort(diskUsed)) of \(formatBytesShort(diskTotal))")
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
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.18))
                Capsule()
                    .fill(usageTint(ratio))
                    .frame(width: proxy.size.width * ratio)
            }
        }
    }

    private func usageTint(_ ratio: Double) -> Color {
        if ratio < 0.8 { return tint }
        if ratio < 0.9 { return .yellow }
        return .red
    }

    private func metricChip(label: String, value: Double, color: Color, arrow: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: arrow)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(formatRateShort(value))
                .font(.caption.monospacedDigit().weight(.medium))
        }
    }

    private func capacityChip(label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(formatBytesShort(value))
                .font(.caption.monospacedDigit().weight(.medium))
        }
    }

    // MARK: - Footer

    private var rateFooter: some View {
        HStack(spacing: 24) {
            footerSlot(title: "Read", value: read, arrow: "arrow.down", color: .green)
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
                Text(formatRateShort(value))
                    .font(.callout.monospacedDigit().weight(.medium))
            }
        }
    }

    // MARK: - Formatters

    private func formatRateHeadline(_ bps: Double) -> String {
        let mbps = bps / 1_048_576
        if mbps >= 100 { return String(format: "%.0f MB/s", mbps) }
        if mbps >= 1 { return String(format: "%.1f MB/s", mbps) }
        let kbps = bps / 1024
        return String(format: "%.0f KB/s", kbps)
    }

    private func formatRateShort(_ bps: Double) -> String {
        let mbps = bps / 1_048_576
        if mbps >= 1 { return String(format: "%.1f MB/s", mbps) }
        let kbps = bps / 1024
        return String(format: "%.0f KB/s", kbps)
    }

    private func formatBytesShort(_ bytes: Double) -> String {
        let gb = bytes / 1_073_741_824
        if gb >= 1000 { return String(format: "%.1f TB", gb / 1024) }
        if gb >= 10 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = bytes / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}
