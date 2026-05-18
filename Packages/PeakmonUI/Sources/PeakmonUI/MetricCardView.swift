//
//  MetricCardView.swift
//  PeakmonUI
//
//  A unified rounded-card surface used by the dashboard popover. Wraps
//  a title row, optional accessory, and arbitrary content.
//

import SwiftUI

public struct MetricCardView<Content: View>: View {
    private let title: String
    private let systemImage: String
    private let tint: Color
    private let accessory: AnyView?
    private let content: Content

    public init(
        title: String,
        systemImage: String,
        tint: Color = .accentColor,
        @ViewBuilder content: () -> Content,
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        accessory = nil
        self.content = content()
    }

    public init(
        title: String,
        systemImage: String,
        tint: Color = .accentColor,
        @ViewBuilder accessory: () -> some View,
        @ViewBuilder content: () -> Content,
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.accessory = AnyView(accessory())
        self.content = content()
    }

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
            Text(value)
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(tint)
        }
    }
}
