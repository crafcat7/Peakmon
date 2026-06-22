//
//  DashboardMetricCard.swift
//  Peakmon
//
//  Shared 3-slot chrome for every dashboard metric card: header,
//  headline, detail (flexes), footer. The rigid layout makes each
//  card in the grid look like a sibling, gives identical chrome
//  (padding / hairline / corner radius), and reduces a new card to
//  filling three closures.
//
//  Height alignment: each card uses a fixed target height
//  (`min/ideal/maxHeight`) so `HStack` rows stay aligned without
//  asking for unbounded vertical flex. Footer content is anchored in
//  a reserved bottom slot so row dividers stay on the same baseline.
//

import SwiftUI

/// Disk and network rates are bursty, so the dashboard keeps a
/// shorter visual window for those high-churn charts. The popover
/// and detailed mini charts can still ask for the full history.
let dashboardRateSparklineSampleLimit = 60

/// Main-window sparklines are glanceable trend hints, not archival
/// charts. Limiting every dashboard chart to the latest 60 samples
/// halves the hot-path copy/domain/path work versus the 120-sample
/// store default while preserving the recent trend at 1-2 s cadence.
let dashboardSparklineSampleLimit = 60

/// Shared safe height for the four information-dense dashboard
/// cards. The content needs this much room to keep footer/detail
/// rows off the rounded bottom edge; the surrounding dashboard
/// chrome is compacted separately so Disk / Network still move up.
let dashboardCardMinHeight: CGFloat = 360

/// Right-side headline trend chart height used by the large cards.
let dashboardHeadlineTrendChartHeight: CGFloat = 92

let dashboardPerCoreChartHeight: CGFloat = 56

let dashboardThermalSparklineHeight: CGFloat = 64

/// Disk and network cards carry fewer independent facts than CPU,
/// memory, GPU, and power. A compact height keeps the rate row from
/// looking unfinished after duplicate throughput stats are removed.
let dashboardRateCardMinHeight: CGFloat = 320

let dashboardRateTrendChartHeight: CGFloat = 140

/// Bottom inset for the reserved footer slot. The footer should read
/// as anchored to the card bottom, not floating above it.
let dashboardCardBottomPadding: CGFloat = 20

/// All large cards reserve the same footer slot so the divider above
/// CPU / Memory / GPU footers lands on the same baseline in a row.
let dashboardCardFooterContentHeight: CGFloat = 40

let dashboardCardFooterSpacing: CGFloat = 12

let dashboardCardFooterBlockHeight: CGFloat = 53

struct DashboardMetricCard<Headline: View, Detail: View, Footer: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    let minHeight: CGFloat

    @ViewBuilder var headline: () -> Headline
    @ViewBuilder var detail: () -> Detail
    @ViewBuilder var footer: () -> Footer

    init(
        title: String,
        systemImage: String,
        tint: Color,
        minHeight: CGFloat = dashboardCardMinHeight,
        @ViewBuilder headline: @escaping () -> Headline,
        @ViewBuilder detail: @escaping () -> Detail = { EmptyView() },
        @ViewBuilder footer: @escaping () -> Footer = { EmptyView() },
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.minHeight = minHeight
        self.headline = headline
        self.detail = detail
        self.footer = footer
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 12) {
                header

                headline()

                detail()

                Spacer(minLength: 0)
            }
            .padding(.top, 20)
            .padding(.horizontal, 20)
            .padding(.bottom, contentBottomPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            footerBlock
                .padding(.horizontal, 20)
                .padding(.bottom, dashboardCardBottomPadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(
            minHeight: minHeight,
            idealHeight: minHeight,
            maxHeight: minHeight,
            alignment: .top,
        )
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.gray.opacity(0.18), lineWidth: 0.5)
        }
        .clipShape(.rect(cornerRadius: 14))
    }

    private var hasFooter: Bool {
        Footer.self != EmptyView.self
    }

    private var contentBottomPadding: CGFloat {
        hasFooter
            ? dashboardCardBottomPadding + dashboardCardFooterBlockHeight
            : dashboardCardBottomPadding
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .padding(7)
                .background(tint.opacity(0.15), in: .rect(cornerRadius: 7))

            Text(title)
                .font(.headline)

            Spacer()
        }
    }

    /// Renders a divider + footer only when the footer slot has
    /// content; an `EmptyView` collapses the strip so footerless
    /// cards don't carry a dangling hairline.
    @ViewBuilder
    private var footerBlock: some View {
        if hasFooter {
            VStack(alignment: .leading, spacing: dashboardCardFooterSpacing) {
                Divider().opacity(0.5)
                footer()
                    .frame(
                        maxWidth: .infinity,
                        minHeight: dashboardCardFooterContentHeight,
                        idealHeight: dashboardCardFooterContentHeight,
                        maxHeight: dashboardCardFooterContentHeight,
                        alignment: .bottom,
                    )
            }
            .frame(height: dashboardCardFooterBlockHeight, alignment: .top)
        }
    }
}

struct DashboardRateBalance {
    let title: String
    let trailing: String?
    let fraction: Double
    let primaryLabel: String
    let primaryValue: String
    let primaryColor: Color
    let secondaryLabel: String
    let secondaryValue: String
    let secondaryColor: Color
}

struct DashboardRateBalanceDetail: View {
    let balance: DashboardRateBalance

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DashboardRateBalanceBlock(balance: balance)
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}

private struct DashboardRateBalanceBlock: View {
    let balance: DashboardRateBalance

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(balance.title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if let trailing = balance.trailing {
                    Text(trailing)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            DashboardSplitBar(
                fraction: balance.fraction,
                primaryColor: balance.primaryColor,
                secondaryColor: balance.secondaryColor,
            )
            .frame(height: 8)

            HStack(spacing: 16) {
                balanceItem(
                    label: balance.primaryLabel,
                    value: balance.primaryValue,
                    color: balance.primaryColor,
                )
                balanceItem(
                    label: balance.secondaryLabel,
                    value: balance.secondaryValue,
                    color: balance.secondaryColor,
                )
                Spacer(minLength: 0)
            }
        }
        .frame(height: 82, alignment: .topLeading)
    }

    private func balanceItem(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .lineLimit(1)
    }
}

private struct DashboardSplitBar: View {
    let fraction: Double
    let primaryColor: Color
    let secondaryColor: Color

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(fraction, 0), 1)
            let primaryWidth = proxy.size.width * clamped

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(secondaryColor.opacity(0.22))
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(primaryColor)
                        .frame(width: primaryWidth)
                    Rectangle()
                        .fill(secondaryColor.opacity(0.72))
                }
                .clipShape(.capsule)
            }
        }
    }
}
