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

import PeakmonUI
import SwiftUI

/// Disk and network rates are bursty, so the dashboard keeps a
/// shorter visual window for those high-churn charts. The popover
/// and detailed mini charts can still ask for the full history.
let dashboardRateSparklineSampleLimit = 60

/// Shared safe height for the four information-dense dashboard
/// cards. The content needs this much room to keep footer/detail
/// rows off the rounded bottom edge; the surrounding dashboard
/// chrome is compacted separately so Disk / Network still move up.
let dashboardCardMinHeight: CGFloat = 300

let dashboardPerCoreChartHeight: CGFloat = 46

/// Disk and network cards carry fewer independent facts than CPU,
/// memory, GPU, and power. A compact height keeps the rate row from
/// looking unfinished after duplicate throughput stats are removed.
let dashboardRateCardMinHeight: CGFloat = 220

/// Shared type and spacing rhythm for every dashboard summary.
/// Keeping these values together prevents six cards from drifting
/// into subtly different baselines and vertical density.
let dashboardSummarySpacing: CGFloat = 7
let dashboardHeadlineUnitSpacing: CGFloat = 5
let dashboardHeadlineNumberSize: CGFloat = 42
let dashboardRateHeadlineNumberSize: CGFloat = 38
let dashboardMetricBarTopPadding: CGFloat = 2

/// A shared pause between the primary summary and the one supporting
/// visual below it. Keeping this vertical rhythm identical prevents
/// the eye from zig-zagging between unrelated left/right regions.
let dashboardDetailTopPadding: CGFloat = 12

/// Bottom inset for the reserved footer slot. The footer should read
/// as anchored to the card bottom, not floating above it.
let dashboardCardBottomPadding: CGFloat = 20

/// All large cards reserve the same footer slot so the divider above
/// CPU / Memory / GPU footers lands on the same baseline in a row.
let dashboardCardFooterContentHeight: CGFloat = 34

let dashboardCardFooterSpacing: CGFloat = 9

let dashboardCardFooterBlockHeight: CGFloat = 44

/// Visual role assigned by the Bento grid. The role controls card
/// chrome without coupling individual metric views to window width.
enum DashboardCardSizeClass: Sendable {
    case hero
    case regular
    case compact
}

private struct DashboardCardSizeClassKey: EnvironmentKey {
    static let defaultValue: DashboardCardSizeClass = .regular
}

private struct DashboardCardTargetHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var dashboardCardTargetHeight: CGFloat? {
        get { self[DashboardCardTargetHeightKey.self] }
        set { self[DashboardCardTargetHeightKey.self] = newValue }
    }

    var dashboardCardSizeClass: DashboardCardSizeClass {
        get { self[DashboardCardSizeClassKey.self] }
        set { self[DashboardCardSizeClassKey.self] = newValue }
    }
}

/// Compact section caption shared by the denser dashboard details.
/// Uppercase + tracking creates the reference panel hierarchy while
/// leaving metric values and the existing tint palette untouched.
struct DashboardSectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
    }
}

struct DashboardMetricCard<Headline: View, Detail: View, Footer: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    let minHeight: CGFloat
    let showsFooter: Bool
    let showsFooterDivider: Bool
    let isEmphasized: Bool

    @Environment(\.dashboardCardTargetHeight) private var targetHeight
    @Environment(\.dashboardCardSizeClass) private var sizeClass

    @ViewBuilder var headline: () -> Headline
    @ViewBuilder var detail: () -> Detail
    @ViewBuilder var footer: () -> Footer

    init(
        title: String,
        systemImage: String,
        tint: Color,
        minHeight: CGFloat = dashboardCardMinHeight,
        showsFooter: Bool? = nil,
        showsFooterDivider: Bool = true,
        isEmphasized: Bool = false,
        @ViewBuilder headline: @escaping () -> Headline,
        @ViewBuilder detail: @escaping () -> Detail = { EmptyView() },
        @ViewBuilder footer: @escaping () -> Footer = { EmptyView() },
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.minHeight = minHeight
        self.showsFooter = showsFooter ?? (Footer.self != EmptyView.self)
        self.showsFooterDivider = showsFooterDivider
        self.isEmphasized = isEmphasized
        self.headline = headline
        self.detail = detail
        self.footer = footer
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 8) {
                header

                headline()

                detail()

                Spacer(minLength: 0)
            }
            .padding(.top, contentPadding)
            .padding(.horizontal, contentPadding)
            .padding(.bottom, contentBottomPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            footerBlock
                .padding(.horizontal, contentPadding)
                .offset(y: footerTopOffset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: resolvedHeight, alignment: .top)
        .peakmonGlassSurface(tint: isEmphasized ? tint : nil)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isEmphasized ? tint.opacity(0.24) : Color.gray.opacity(0.18),
                    lineWidth: 0.5,
                )
        }
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
    }

    private var hasFooter: Bool {
        showsFooter
    }

    private var resolvedHeight: CGFloat {
        targetHeight ?? minHeight
    }

    private var contentBottomPadding: CGFloat {
        hasFooter
            ? contentPadding + dashboardCardFooterBlockHeight
            : contentPadding
    }

    private var footerTopOffset: CGFloat {
        resolvedHeight - contentPadding - dashboardCardFooterBlockHeight
    }

    private var contentPadding: CGFloat {
        switch sizeClass {
        case .hero: 16
        case .regular: 15
        case .compact: 13
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(tint.opacity(0.13), in: .rect(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(tint.opacity(0.20), lineWidth: 0.5)
                }

            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.55)

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
                if showsFooterDivider {
                    Divider().opacity(0.5)
                } else {
                    // Preserve the shared footer baseline while
                    // removing only the visible separator.
                    Color.clear.frame(height: 1)
                }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                DashboardSectionLabel(title: balance.title)
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
            .frame(height: 6)

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
        .frame(height: 66, alignment: .topLeading)
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
