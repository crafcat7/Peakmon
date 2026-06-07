//
//  DashboardComponents.swift
//  PeakmonUI
//
//  Shared UI primitives used across multiple dashboard cards.
//  Extracted to eliminate duplication and guarantee visual
//  consistency between popover and main-window surfaces.
//

import SwiftUI

// MARK: - MetricChipView

/// Compact inline chip: coloured dot (or SF Symbol arrow) + label
/// + value. Used in collapsed card summaries to show secondary
/// metrics (temp, power, memory, fan RPM, network rates, etc.).
public struct MetricChipView: View {
    let label: String
    let value: String
    let color: Color
    let arrow: String?

    /// Standard chip with a coloured dot.
    public init(label: String, value: String, color: Color) {
        self.label = label
        self.value = value
        self.color = color
        self.arrow = nil
    }

    /// Chip with an SF Symbol arrow instead of a coloured dot.
    /// Used by Network and Disk cards for directional indicators.
    public init(label: String, value: String, color: Color, arrow: String) {
        self.label = label
        self.value = value
        self.color = color
        self.arrow = arrow
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let arrow {
                Image(systemName: arrow)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
        }
    }
}

// MARK: - FooterStatView

/// Single stat block in a card footer: title label above a
/// monospaced value. Used by GPU, Power, Disk, Network cards.
/// Optionally prefixed with an SF Symbol arrow for directional
/// indicators (e.g. network in/out, disk read/write).
public struct FooterStatView: View {
    let title: String
    let value: String
    let color: Color
    let arrow: String?

    /// Standard footer stat (no arrow).
    public init(title: String, value: String, color: Color) {
        self.title = title
        self.value = value
        self.color = color
        self.arrow = nil
    }

    /// Footer stat with an SF Symbol arrow prefix.
    public init(title: String, value: String, color: Color, arrow: String) {
        self.title = title
        self.value = value
        self.color = color
        self.arrow = arrow
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                if let arrow {
                    Image(systemName: arrow)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(color)
                }
                Text(value)
                    .font(.callout.monospacedDigit().weight(.medium))
                    .foregroundStyle(color)
            }
        }
    }
}

// MARK: - ProportionalBarView

/// Horizontal bar that fills to a fraction of its width. Replaces
/// the `GeometryReader { Capsule().fill(...).frame(width:) }`
/// pattern repeated across 7+ dashboard cards. Uses a Canvas
/// internally to avoid the two-pass layout cost of GeometryReader.
public struct ProportionalBarView: View {
    let fraction: Double
    let color: Color
    let height: CGFloat
    let backgroundOpacity: Double

    /// - Parameters:
    ///   - fraction: Fill ratio, 0...1. Values outside this range
    ///     are clamped.
    ///   - color: Fill colour. Background is the same colour at
    ///     `backgroundOpacity`.
    ///   - height: Bar height in points.
    ///   - backgroundOpacity: Opacity of the unfilled background.
    public init(
        fraction: Double,
        color: Color,
        height: CGFloat = 6,
        backgroundOpacity: Double = 0.18,
    ) {
        self.fraction = fraction
        self.color = color
        self.height = height
        self.backgroundOpacity = backgroundOpacity
    }

    public var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let path = Capsule().path(in: rect)

            // Background
            context.fill(path, with: .color(color.opacity(backgroundOpacity)))

            // Filled portion
            let clamped = min(max(fraction, 0), 1)
            let fillWidth = size.width * clamped
            if fillWidth > 0 {
                let fillRect = CGRect(x: 0, y: 0, width: fillWidth, height: size.height)
                let fillPath = Capsule().path(in: fillRect)
                context.fill(fillPath, with: .color(color))
            }
        }
        .frame(height: height)
    }
}

// MARK: - LabeledBarRow

/// A row with a label, proportional bar, and monospaced value.
/// Used for rail breakdowns (Power card, GPU card) and memory
/// composition (Memory card).
public struct LabeledBarRow: View {
    let label: String
    let value: String
    let fraction: Double
    let color: Color
    let labelWidth: CGFloat
    let valueWidth: CGFloat
    let barHeight: CGFloat

    public init(
        label: String,
        value: String,
        fraction: Double,
        color: Color,
        labelWidth: CGFloat = 70,
        valueWidth: CGFloat = 72,
        barHeight: CGFloat = 6,
    ) {
        self.label = label
        self.value = value
        self.fraction = fraction
        self.color = color
        self.labelWidth = labelWidth
        self.valueWidth = valueWidth
        self.barHeight = barHeight
    }

    public var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption.weight(.medium))
                .frame(width: labelWidth, alignment: .leading)
            ProportionalBarView(
                fraction: fraction,
                color: color,
                height: barHeight,
            )
            Text(value)
                .font(.caption.monospacedDigit())
                .frame(width: valueWidth, alignment: .trailing)
        }
    }
}
