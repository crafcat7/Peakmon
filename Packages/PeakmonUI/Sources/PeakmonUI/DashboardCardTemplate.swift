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
    /// Pinned height of the stats row. Calibrated for caption2 (12pt)
    /// + 2pt spacing + callout (~17pt) plus a 2pt baseline cushion;
    /// keeps the row's bottom edge stable when `minimumScaleFactor`
    /// triggers inside a `MetricStatLabel`.
    public static let statsRowHeight: CGFloat = 36

    /// Pinned chart slot height. Matches the prior hard-coded
    /// `.frame(height: 48)` on every sparkline.
    public static let chartHeight: CGFloat = 48

    /// Spacing between stats row and chart slot. Matches the prior
    /// hand-written VStack spacing in `DashboardView`.
    public static let interSlotSpacing: CGFloat = 10

    /// Cap on visible stats in `.half` density. Two-stat compaction
    /// matches the Disk/Network half-width target use case; full
    /// cards reveal the remainder.
    public static let halfStatsCap: Int = 2
}

/// The template itself. Generic over the accessory, chart, and
/// overlay view types so SwiftUI preserves view identity across
/// re-evaluations (no `AnyView` round-trips).
public struct DashboardCardTemplate<Accessory: View, Chart: View, CardOverlay: View>: View {
    @Environment(\.cardDensity) private var density

    private let title: String
    private let systemImage: String
    private let tint: Color
    private let accessory: Accessory
    private let stats: [CardStat]
    private let chart: Chart
    private let cardOverlay: CardOverlay

    public init(
        title: String,
        systemImage: String,
        tint: Color = .accentColor,
        stats: [CardStat],
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder chart: () -> Chart,
        @ViewBuilder overlay: () -> CardOverlay = { EmptyView() },
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.accessory = accessory()
        self.stats = stats
        self.chart = chart()
        cardOverlay = overlay()
    }

    public var body: some View {
        MetricCardView(
            title: title,
            systemImage: systemImage,
            tint: tint,
            accessory: { accessory },
            content: {
                VStack(alignment: .leading, spacing: DashboardCardMetrics.interSlotSpacing) {
                    statsRow
                    chart
                        .frame(height: DashboardCardMetrics.chartHeight)
                }
            },
        )
        .overlay { cardOverlay }
    }

    /// Renders the user-declared stats, truncated by `halfStatsCap`
    /// when laying out at half density. The row's height is pinned
    /// even when empty (e.g. Memory's single-stat case) so single-
    /// and triple-stat cards still align vertically.
    @ViewBuilder
    private var statsRow: some View {
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
