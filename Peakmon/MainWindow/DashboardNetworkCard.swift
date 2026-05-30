//
//  DashboardNetworkCard.swift
//  Peakmon
//
//  Network panel using the shared `DashboardMetricCard` chrome.
//
//  No per-interface / per-process drill-down: `getifaddrs` gives
//  per-interface byte counters that don't map cleanly to "what's
//  using my bandwidth", and per-process answers need entitlements
//  out of reach for ad-hoc signing. So the card shows the aggregate
//  in/out rate, chips, dual sparkline, and a totals detail block.
//

import PeakmonCore
import PeakmonUI
import SwiftUI

struct DashboardNetworkCard: View {
    @Environment(MetricsStore.self) private var store
    @Environment(\.cardSettings) private var cardSettings

    private var tint: Color { cardSettings.tint(.network) }

    private var netIn: Double { store.value(for: .netInRate) }
    private var netOut: Double { store.value(for: .netOutRate) }

    var body: some View {
        DashboardMetricCard(
            title: "Network",
            systemImage: "network",
            tint: tint,
            headline: { headlineRow },
            detail: { throughputDetail },
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
                Text(formatRateHeadline(max(netIn, netOut)))
                    .font(.system(size: 32, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(value: max(netIn, netOut)))
                    .animation(.smooth, value: max(netIn, netOut))
                Text("peak")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text("Up + down throughput")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                metricChip(label: "in", value: netIn, color: .green, arrow: "arrow.down")
                metricChip(label: "out", value: netOut, color: .blue, arrow: "arrow.up")
            }
        }
    }

    private var trendChart: some View {
        MetricSparklineView(series: [
            SparklineSeries(
                id: "net.in",
                samples: store.history(for: .netInRate),
                color: .green,
            ),
            SparklineSeries(
                id: "net.out",
                samples: store.history(for: .netOutRate),
                color: .blue,
            ),
        ])
    }

    // MARK: - Detail

    /// Throughput recap fills the detail slot: the headline numbers
    /// as discrete rate rows with arrows, so the card matches its
    /// row-mate (Disk) in height.
    private var throughputDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Live throughput")
                .font(.subheadline.weight(.semibold))

            VStack(spacing: 6) {
                throughputRow(label: "Inbound", value: netIn, color: .green, arrow: "arrow.down")
                throughputRow(label: "Outbound", value: netOut, color: .blue, arrow: "arrow.up")
            }
        }
    }

    private func throughputRow(label: String, value: Double, color: Color, arrow: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: arrow)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 14)
            Text(label)
                .font(.caption.weight(.medium))
                .frame(width: 80, alignment: .leading)
            Text(formatRateShort(value))
                .font(.callout.monospacedDigit())
                .foregroundStyle(value > 1024 ? .primary : .secondary)
            Spacer()
        }
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

    // MARK: - Footer

    private var rateFooter: some View {
        HStack(spacing: 24) {
            footerSlot(title: "In", value: netIn, arrow: "arrow.down", color: .green)
            footerSlot(title: "Out", value: netOut, arrow: "arrow.up", color: .blue)
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
}
