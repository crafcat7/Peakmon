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
            footer: { EmptyView() },
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
        VStack(alignment: .leading, spacing: 12) {
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
                    MetricChipView(label: "used", value: DashboardFormatting.bytesShort(diskUsed), color: usageTint(ratio))
                    MetricChipView(label: "free", value: DashboardFormatting.bytesShort(max(diskTotal - diskUsed, 0)), color: .secondary)
                    Spacer()
                    Text(String(format: "%.0f%%", ratio * 100))
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(usageTint(ratio))
                }
            }

            HStack(spacing: 12) {
                sparkline(title: "Read", value: DashboardFormatting.rateShort(read), color: .blue, samples: store.history(for: .diskReadRate))
                sparkline(title: "Write", value: DashboardFormatting.rateShort(write), color: .orange, samples: store.history(for: .diskWriteRate))
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

    private func sparkline(title: String, value: String, color: Color, samples: [MetricSample]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(color)
            }
            MetricSparklineView(
                samples: samples,
                style: SparklineStyle(
                    color: color,
                    fillOpacity: 0.2,
                    lineWidth: 1.4,
                    yMin: 0,
                    yMax: nil,
                ),
            )
            .frame(height: 40)
        }
    }
}
