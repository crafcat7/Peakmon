//
//  DashboardMetricCard.swift
//  Peakmon
//
//  Shared 3-slot chrome for every dashboard metric card. The
//  layout vocabulary is intentionally rigid so each card in the
//  grid looks like a sibling rather than a snowflake:
//
//    ┌──────────────────────────────────────────┐
//    │  ◉ Title                                 │  ← header (32pt)
//    ├──────────────────────────────────────────┤
//    │  headline slot                           │  ← ~110pt
//    │  (32pt number + chips + sparkline)       │
//    ├──────────────────────────────────────────┤
//    │  detail slot                             │  ← flexes
//    │  (per-card content, may be empty)        │
//    ├──────────────────────────────────────────┤
//    │  footer slot                             │  ← ~36pt
//    └──────────────────────────────────────────┘
//
//  Every card on the dashboard renders through this container so
//  that:
//    • Header, padding, hairline, corner radius are identical.
//    • A row's cards reach the same height — set by the tallest
//      sibling — instead of producing ragged whitespace under
//      shorter siblings (the bug that motivated this refactor).
//    • Adding a new card means filling three closures rather than
//      reinventing chrome.
//
//  Height alignment trick: every card declares
//  `frame(minHeight: cardMinHeight, maxHeight: .infinity)` so
//  HStack/Grid rows stretch them to the tallest neighbour, with
//  internal `Spacer()`s pushing the footer to the bottom.
//
//  Headline / detail / footer are all `@ViewBuilder` and any can
//  be `EmptyView()` for cards that don't have a slot (e.g. some
//  cards omit `detail`).
//

import SwiftUI

/// Shared minimum height for every dashboard card. Picked to
/// fit the heaviest current card (CPU with per-core bars) plus
/// a little breathing room; thinner cards Spacer themselves up
/// to the same height so a row of two cards looks symmetrical.
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

            // `detail` slot grows to fill the card. The empty-view
            // case still occupies a Spacer so the footer sticks to
            // the bottom regardless of slot content.
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

    /// Footer renders a divider above only when the footer slot
    /// actually has content; an `EmptyView` collapses the strip
    /// entirely so cards without footer payload don't carry a
    /// dangling hairline.
    @ViewBuilder
    private var footerBlock: some View {
        if Footer.self != EmptyView.self {
            Divider().opacity(0.5)
            footer()
        }
    }
}
