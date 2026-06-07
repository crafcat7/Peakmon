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
            detail: { sparklineDetail },
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
                Text(DashboardFormatting.rateHeadline(max(netIn, netOut)))
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
                MetricChipView(label: "in", value: DashboardFormatting.rateShort(netIn), color: .green, arrow: "arrow.down")
                MetricChipView(label: "out", value: DashboardFormatting.rateShort(netOut), color: .pink, arrow: "arrow.up")
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
                color: .pink,
            ),
        ])
    }

    // MARK: - Detail

    /// Dual sparkline showing inbound and outbound rates
    /// separately, providing more granular trend visibility
    /// than the combined headline sparkline.
    private var sparklineDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            miniSeries(
                title: "Download",
                value: DashboardFormatting.rateShort(netIn),
                color: .green,
                samples: store.history(for: .netInRate),
            )
            miniSeries(
                title: "Upload",
                value: DashboardFormatting.rateShort(netOut),
                color: .pink,
                samples: store.history(for: .netOutRate),
            )
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func miniSeries(title: String, value: String, color: Color, samples: [MetricSample]) -> some View {
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
