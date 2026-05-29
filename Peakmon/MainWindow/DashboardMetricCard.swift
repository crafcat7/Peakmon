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
//  Height alignment: every card declares `frame(minHeight:
//  cardMinHeight, maxHeight: .infinity)` so a row's cards all reach
//  the tallest sibling's height (instead of ragged whitespace
//  under shorter ones), with internal `Spacer()`s pinning the
//  footer to the bottom. Each slot is a `@ViewBuilder` and may be
//  `EmptyView()`.
//

import SwiftUI

/// Shared minimum height for every dashboard card. Sized to the
/// heaviest card (CPU with per-core bars); thinner cards Spacer up
/// to match so a row of two looks symmetrical.
let dashboardCardMinHeight: CGFloat = 360

struct DashboardMetricCard<Headline: View, Detail: View, Footer: View>: View {
    let title: String
    let systemImage: String
    let tint: Color

    @ViewBuilder var headline: () -> Headline
    @ViewBuilder var detail: () -> Detail
    @ViewBuilder var footer: () -> Footer

    init(
        title: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder headline: @escaping () -> Headline,
        @ViewBuilder detail: @escaping () -> Detail = { EmptyView() },
        @ViewBuilder footer: @escaping () -> Footer = { EmptyView() },
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.headline = headline
        self.detail = detail
        self.footer = footer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            headline()

            // `detail` grows to fill the card; the empty case still
            // takes a Spacer so the footer stays pinned to the
            // bottom regardless of slot content.
            detail()

            Spacer(minLength: 0)

            footerBlock
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: dashboardCardMinHeight, maxHeight: .infinity, alignment: .top)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.gray.opacity(0.18), lineWidth: 0.5)
        }
        .clipShape(.rect(cornerRadius: 14))
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
        if Footer.self != EmptyView.self {
            Divider().opacity(0.5)
            footer()
        }
    }
}
