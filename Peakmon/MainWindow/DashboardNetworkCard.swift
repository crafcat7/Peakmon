//
//  DashboardNetworkCard.swift
//  Peakmon
//
//  Network panel using the shared `DashboardMetricCard` chrome.
//
//  No per-interface / per-process drill-down: `getifaddrs` gives
//  per-interface byte counters that don't map cleanly to "what's
//  using my bandwidth", and per-process answers need entitlements
//  out of reach for ad-hoc signing. So the card shows total transfer,
//  in/out chips, one dual sparkline, and direction mix without
//  repeating the same current-rate numbers.
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
    private var transferTotal: Double { max(0, netIn + netOut) }
    private var inboundShare: Double {
        transferTotal > 0 ? netIn / transferTotal : 0.5
    }

    var body: some View {
        DashboardMetricCard(
            title: "Network",
            systemImage: "network",
            tint: tint,
            minHeight: dashboardRateCardMinHeight,
            headline: { headlineRow },
            detail: { transferDetail },
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
                Text(DashboardFormatting.rateHeadline(transferTotal))
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
            MetricChipView(label: "in", value: DashboardFormatting.rateShort(netIn), color: .green, arrow: "arrow.down")
            MetricChipView(label: "out", value: DashboardFormatting.rateShort(netOut), color: .pink, arrow: "arrow.up")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trendChart: some View {
        MetricSparklineView(series: [
            SparklineSeries(
                id: "net.in",
                samples: store.historySuffix(for: .netInRate, limit: dashboardRateSparklineSampleLimit),
                color: .green,
            ),
            SparklineSeries(
                id: "net.out",
                samples: store.historySuffix(for: .netOutRate, limit: dashboardRateSparklineSampleLimit),
                color: .pink,
            ),
        ])
    }

    // MARK: - Detail

    /// Mirrors Disk's detail slot with a single fixed-height summary
    /// block. Current in/out rates stay in the headline chips so the
    /// detail area can show only the direction split.
    private var transferDetail: some View {
        DashboardRateBalanceDetail(
            balance: DashboardRateBalance(
                title: "Direction mix",
                trailing: nil,
                fraction: inboundShare,
                primaryLabel: "In",
                primaryValue: String(format: "%.0f%%", inboundShare * 100),
                primaryColor: .green,
                secondaryLabel: "Out",
                secondaryValue: String(format: "%.0f%%", (1 - inboundShare) * 100),
                secondaryColor: .pink,
            ),
        )
    }
}
