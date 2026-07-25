//
//  DashboardCardTemplate.swift
//  PeakmonUI
//
//  High-level template that every dashboard metric card renders
//  through. Centralises layout decisions (stats row height, chart
//  height, half-width stat-count cap) so individual cards only
//  declare *what* they show, not *how* it is laid out. Adding a new
//  metric to the dashboard becomes a matter of filling in the
//  template's slots; nothing in the card itself can drift from the
//  shared visual contract.
//
//  Equal-height invariant:
//    * stats row is pinned to `Metrics.statsRowHeight` so the row's
//      bottom edge does not move when individual `MetricStatLabel`s
//      engage `minimumScaleFactor`,
//    * the chart slot is pinned to `Metrics.chartHeight`,
//    * the surrounding `MetricCardView` adds a fixed padding +
//      header height,
//  which together guarantee every card materialised by this
//  template has the same outer height regardless of width or stats
//  count. Paired half cards stop jittering as data flows in, and
//  full-width cards line up cleanly when stacked above/below each
//  other.
//

import SwiftUI

/// Whether a card is currently laid out at full popover width or as
/// a half-width tile. Pulled from the environment so each card can
/// adapt without the dashboard threading the value through every
/// initialiser.
public enum CardDensity: Equatable, Sendable {
    case full
    case half
}

private struct CardDensityKey: EnvironmentKey {
    static let defaultValue: CardDensity = .full
}

extension EnvironmentValues {
    public var cardDensity: CardDensity {
        get { self[CardDensityKey.self] }
        set { self[CardDensityKey.self] = newValue }
    }
}

/// Declarative description of one stat block inside a card. Cards
/// hand the template an *ordered* list; the template decides how
/// many to render based on the current `CardDensity`.
public struct CardStat: Identifiable {
    public let id: String
    public let label: String
    public let value: String
    public let tint: Color

    public init(label: String, value: String, tint: Color = .primary) {
        id = label
        self.label = label
        self.value = value
        self.tint = tint
    }
}

/// Shared layout constants for the template. Exposed publicly so
/// callers can match heights from outside (e.g. a custom card body
/// that bypasses `chart:` can still use `chartHeight` to size its
/// own contents and stay equal-height with template-rendered
/// neighbours).
public enum DashboardCardMetrics {
    /// Outer height of the six primary metric cards in the Popover.
    /// The 136 pt tile still contains the full 80 pt stats + chart
    /// body while recovering enough vertical room for five process
    /// rows inside the fixed 760 pt window.
    public static let cardMinimumHeight: CGFloat = 136

    /// Pinned height of the stats row. Calibrated for caption2 (12pt)
    /// + 2pt spacing + callout (~17pt) plus a 2pt baseline cushion;
    /// keeps the row's bottom edge stable when `minimumScaleFactor`
    /// triggers inside a `MetricStatLabel`.
    public static let statsRowHeight: CGFloat = 36

    /// Compact chart slot. The Popover is a quick glance surface;
    /// detailed temporal inspection remains available in History.
    public static let chartHeight: CGFloat = 36

    /// Spacing between stats row and chart slot. Matches the prior
    /// hand-written VStack spacing in `DashboardView`.
    public static let interSlotSpacing: CGFloat = 8

    /// Cap on visible stats in `.half` density. Two-stat compaction
    /// matches the Disk/Network half-width target use case; full
    /// cards reveal the remainder.
    public static let halfStatsCap: Int = 2

    /// Combined inner content height: `statsRowHeight` + spacing +
    /// `chartHeight`. Cards that opt out of the stats-plus-chart
    /// shape (e.g. a process list) use this as the pinned height
    /// of their free-form body so they stay equal-height with the
    /// rest of the dashboard.
    public static var contentHeight: CGFloat {
        statsRowHeight + interSlotSpacing + chartHeight
    }
}

/// The template itself. Generic over the accessory, body, and
/// overlay view types so SwiftUI preserves view identity across
/// re-evaluations (no `AnyView` round-trips). Two layout modes are
/// supported via the private `Layout` enum:
///
///   * `.statsAndChart` — the canonical metric shape (stats row +
///     pinned-height chart slot). Built through the `chart:` init.
///   * `.freeform` — caller-supplied content occupying the full
///     content area at the pinned `contentHeight`. Built through
///     the `body:` init. Used by Processes, where rows are not a
///     sparkline and the stats row is not meaningful.
///
/// Both modes default to `DashboardCardMetrics.contentHeight`; compact
/// summary cards may override the content and outer heights explicitly.
public struct DashboardCardTemplate<Accessory: View, Body: View, CardOverlay: View>: View {
    @Environment(\.cardDensity) private var density

    private let title: String
    private let systemImage: String
    private let tint: Color
    private let minimumHeight: CGFloat
    private let contentHeight: CGFloat
    private let accessory: Accessory
    private let layout: Layout
    private let cardOverlay: CardOverlay

    private enum Layout {
        case statsAndChart(stats: [CardStat], chart: Body)
        case freeform(body: Body)
    }

    /// `stats + chart` init: the metric-card shape. Most cards on
    /// the dashboard use this.
    public init(
        title: String,
        systemImage: String,
        tint: Color = .accentColor,
        minimumHeight: CGFloat = DashboardCardMetrics.cardMinimumHeight,
        contentHeight: CGFloat = DashboardCardMetrics.contentHeight,
        stats: [CardStat],
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder chart: () -> Body,
        @ViewBuilder overlay: () -> CardOverlay = { EmptyView() },
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.minimumHeight = minimumHeight
        self.contentHeight = contentHeight
        self.accessory = accessory()
        layout = .statsAndChart(stats: stats, chart: chart())
        cardOverlay = overlay()
    }

    /// Free-form body init: the caller takes responsibility for the
    /// content layout, but the template still pins the outer height
    /// so the card stays equal-height with its neighbours. The body
    /// closure receives the available height as its first argument
    /// — actually, the wrapper just constrains the body's frame, so
    /// the caller need not know the exact number.
    public init(
        title: String,
        systemImage: String,
        tint: Color = .accentColor,
        minimumHeight: CGFloat = DashboardCardMetrics.cardMinimumHeight,
        contentHeight: CGFloat = DashboardCardMetrics.contentHeight,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder body: () -> Body,
        @ViewBuilder overlay: () -> CardOverlay = { EmptyView() },
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.minimumHeight = minimumHeight
        self.contentHeight = contentHeight
        self.accessory = accessory()
        layout = .freeform(body: body())
        cardOverlay = overlay()
    }

    public var body: some View {
        MetricCardView(
            title: title,
            systemImage: systemImage,
            tint: tint,
            minimumHeight: minimumHeight,
            accessory: { accessory },
            content: { contentView },
        )
        .overlay { cardOverlay }
    }

    @ViewBuilder
    private var contentView: some View {
        switch layout {
        case let .statsAndChart(stats, chart):
            VStack(alignment: .leading, spacing: DashboardCardMetrics.interSlotSpacing) {
                statsRow(stats: stats)
                chart
                    .frame(height: DashboardCardMetrics.chartHeight)
            }
        case let .freeform(bodyContent):
            bodyContent
                .frame(
                    maxWidth: .infinity,
                    minHeight: contentHeight,
                    maxHeight: contentHeight,
                    alignment: .topLeading,
                )
        }
    }

    /// Renders the user-declared stats, truncated by `halfStatsCap`
    /// when laying out at half density. The row's height is pinned so
    /// cards with different stat counts still align vertically.
    @ViewBuilder
    private func statsRow(stats: [CardStat]) -> some View {
        let visible = density == .half
            ? Array(stats.prefix(DashboardCardMetrics.halfStatsCap))
            : stats
        HStack(alignment: .top, spacing: 18) {
            ForEach(visible) { stat in
                MetricStatLabel(label: stat.label, value: stat.value, tint: stat.tint)
            }
            Spacer(minLength: 0)
        }
        .frame(height: DashboardCardMetrics.statsRowHeight, alignment: .top)
    }
}
