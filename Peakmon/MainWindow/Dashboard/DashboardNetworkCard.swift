//
//  DashboardNetworkCard.swift
//  Peakmon
//
//  Network panel using the shared `DashboardMetricCard` chrome.
//
//  No per-interface / per-process drill-down: `getifaddrs` gives
//  per-interface byte counters that don't map cleanly to "what's
//  using my bandwidth", and per-process answers need entitlements
//  out of reach for ad-hoc signing. The card keeps total transfer,
//  its in/out components, and one trend; the former direction-mix
//  block repeated the same relationship and has been removed.
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

    /// Network has no non-duplicative detail block, so its one chart
    /// follows the summary vertically instead of pulling attention
    /// into a separate right-hand region.
    private let trendHeight: CGFloat = 52

    var body: some View {
        DashboardMetricCard(
            title: "Network",
            systemImage: "network",
            tint: tint,
            minHeight: dashboardRateCardMinHeight,
            isEmphasized: true,
            headline: { headlineRow },
        )
    }

    private var headlineRow: some View {
        VStack(alignment: .leading, spacing: dashboardDetailTopPadding) {
            summary
            trendChart
                .frame(maxWidth: .infinity)
                .frame(height: trendHeight)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: dashboardSummarySpacing) {
            Text(DashboardFormatting.rateHeadline(transferTotal))
                .font(.system(size: dashboardRateHeadlineNumberSize, weight: .bold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            throughputChips
        }
    }

    private var throughputChips: some View {
        HStack(spacing: 10) {
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

}
