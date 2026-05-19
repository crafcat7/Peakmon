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
        }
    }
}
