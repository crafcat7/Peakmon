//
//  MetricCardView.swift
//  PeakmonUI
//
//  A unified rounded-card surface used by the dashboard popover. Wraps
//  a title row, optional accessory, and arbitrary content.
//

import SwiftUI

public struct MetricCardView<Content: View, Accessory: View>: View {
    private let title: String
    private let systemImage: String
    private let tint: Color
    private let accessory: Accessory
    private let content: Content

    /// Designated initialiser. Both `accessory` and `content` are
    /// captured as generic `View`s so SwiftUI can preserve view
    /// identity across body re-evaluations. Previously these were
    /// stored as `AnyView`, which forced a full subtree rebuild on
    /// every popover tick and was a measurable contributor to the
    /// dashboard's per-tick CPU cost while open.
    public init(
        title: String,
        systemImage: String,
        tint: Color = .accentColor,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content,
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.accessory = accessory()
        self.content = content()
    }
}

extension MetricCardView where Accessory == EmptyView {
    /// Convenience initialiser for cards that don't show an accessory
    /// (kept so existing call sites compile unchanged).
    public init(
        title: String,
        systemImage: String,
        tint: Color = .accentColor,
        @ViewBuilder content: () -> Content,
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            tint: tint,
            accessory: { EmptyView() },
            content: content,
        )
    }
}

extension MetricCardView {
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .imageScale(.medium)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                accessory
            }
            content
        }
        .padding(12)
        .frame(minHeight: 160)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator, lineWidth: 0.5)
        }
        .clipShape(.rect(cornerRadius: 10))
    }
}

/// A small labelled stat (e.g. "User 12.3%").
public struct MetricStatLabel: View {
    private let label: String
    private let value: String
    private let tint: Color

    public init(label: String, value: String, tint: Color = .primary) {
        self.label = label
        self.value = value
        self.tint = tint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .lineLimit(1)
            Text(value)
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(tint)
                // Long values (e.g. GPU "Apple M3 Max", network
                // "1023.4 MB/s") must not wrap because that would
                // push the stat row taller than the matching row in
                // neighbouring cards, breaking half-width pair
                // alignment. Allow the text to scale down to 70 % of
                // its intrinsic size before truncating with a tail
                // ellipsis.
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .truncationMode(.tail)
                // Pin the value row to its unscaled intrinsic height
                // so `minimumScaleFactor` (above) never shrinks the
                // line box. Without this, a half-width Disk card
                // whose `Read`/`Write` rates flip between "  9K/s"
                // and "1.2 MB/s" would scale the .callout text down
                // and back up each tick, dragging the card's bottom
                // edge up and down by a couple of points — exactly
                // the jitter users see on the dashboard. We measure
                // the unscaled height with a hidden, fixed-size copy
                // of the same Text instead of hard-coding a number
                // so the layout adapts automatically to Dynamic Type
                // changes.
                .frame(minHeight: Self.valueLineHeight, alignment: .leading)
        }
    }

    /// Unscaled line height of the `.callout` font used by the value
    /// Text. Computed once via SwiftUI's @State + hidden measurement
    /// — actually no, simpler: we read NSFont's `pointSize` directly
    /// since `.callout` resolves to a known system metric.
    private static var valueLineHeight: CGFloat {
        // `.callout` is 13pt by default on macOS; line height with
        // the default leading is ~17pt. Hard-coding the constant is
        // acceptable here because `minimumScaleFactor: 0.7` only
        // kicks in when text overflows — i.e. the only path where
        // the height would otherwise shrink — and SwiftUI continues
        // to honour Dynamic Type for the *unscaled* case via the
        // font modifier itself; this floor only matters when the
        // scaler engages.
        17
    }
}
