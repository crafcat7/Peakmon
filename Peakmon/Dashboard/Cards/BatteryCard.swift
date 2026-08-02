//
//  BatteryCard.swift
//  Peakmon
//
//  Popover battery card: status-first presentations for half-width
//  and full-width rows. Battery level changes too slowly for a tiny
//  sparkline to add diagnostic value here, so both variants dedicate
//  their space to source, health, cycles, level, and temperature.
//

import PeakmonCore
import PeakmonUI
import SwiftUI

enum BatteryCardPresentation {
    case standard
    case compactStrip
}

struct BatteryCard: View {
    var presentation: BatteryCardPresentation = .standard

    @Environment(MetricsStore.self) private var store
    @Environment(\.cardSettings) private var cardSettings

    private var tint: Color { cardSettings.tint(.battery) }
    private var sample: MetricSample? { store.latest(for: .batteryLevel) }
    private var source: BatteryPowerSource {
        guard let s = store.latest(for: .batteryPowerSource) else { return .onBattery }
        return BatteryPowerSource(metricValue: s.value)
    }
    private var cycles: Int? {
        store.latest(for: .batteryCycleCount).map { Int($0.value) }
    }
    private var health: Double? {
        store.latest(for: .batteryHealth)?.value
    }
    private var temperature: Double? {
        store.latest(for: .batteryTemperature)?.value
    }
    private var timeRemainingSeconds: Double? {
        store.latest(for: .batteryTimeRemaining)?.value
    }

    @ViewBuilder
    var body: some View {
        let level = sample?.value ?? 0
        let src = source
        let isLow = src == .onBattery && level < 20
        let iconTint: Color = isLow ? .red : tint
        let iconName = isLow ? "battery.0percent" : Self.iconName(for: level, source: src)

        switch presentation {
        case .standard:
            DashboardCardTemplate(
                title: "Battery",
                systemImage: iconName,
                tint: iconTint,
                accessory: {
                    accessoryStack(level: level, source: src)
                },
                body: {
                    halfWidthStatusFacts(source: src)
                },
            )
            .overlay(alignment: .topLeading) {
                if let dotColor = Self.cornerDotColor(for: src) {
                    BatteryCornerDot(color: dotColor)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: src)

        case .compactStrip:
            compactStrip(
                level: level,
                source: src,
                iconName: iconName,
                iconTint: iconTint,
            )
        }
    }

    /// Status-only body used when Battery is paired with another
    /// half-width card. The facts follow one vertical reading path:
    /// source first, then long-term condition. This avoids reserving
    /// the lower half of the card for an almost-flat charge trace.
    private func halfWidthStatusFacts(source: BatteryPowerSource) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            compactFact(
                label: "Source",
                value: sourceValue(src: source),
                tint: tint,
                minimumWidth: 0,
            )

            HStack(spacing: 28) {
                if let health {
                    compactFact(
                        label: "Health",
                        value: String(format: "%.0f%%", health),
                        tint: Self.healthTint(health: health, base: tint),
                        minimumWidth: 0,
                    )
                }
                if let cycles {
                    compactFact(
                        label: "Cycles",
                        value: "\(cycles)",
                        tint: .secondary,
                        minimumWidth: 0,
                    )
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// A full-width status row for the common unpaired Battery slot.
    /// The recovered horizontal room is used for facts that can be
    /// scanned without leaving an empty half-row beside the card.
    private func compactStrip(
        level: Double,
        source: BatteryPowerSource,
        iconName: String,
        iconTint: Color,
    ) -> some View {
        MetricCardView(
            title: "Battery",
            systemImage: iconName,
            tint: iconTint,
            minimumHeight: 80,
            accessory: {
                accessoryStack(level: level, source: source)
            },
            content: {
                HStack(spacing: 0) {
                    compactFact(label: "Source", value: sourceValue(src: source), tint: tint)
                    compactDivider
                    if let health {
                        compactFact(
                            label: "Health",
                            value: String(format: "%.0f%%", health),
                            tint: Self.healthTint(health: health, base: tint),
                        )
                        compactDivider
                    }
                    if let cycles {
                        compactFact(label: "Cycles", value: "\(cycles)", tint: .secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            },
        )
        .overlay(alignment: .topLeading) {
            if let dotColor = Self.cornerDotColor(for: source) {
                BatteryCornerDot(color: dotColor)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: source)
    }

    private func compactFact(
        label: String,
        value: String,
        tint: Color,
        minimumWidth: CGFloat = 96,
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(label))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(minWidth: minimumWidth, alignment: .leading)
    }

    private var compactDivider: some View {
        Divider()
            .frame(height: 28)
            .padding(.horizontal, 16)
    }

    /// Source-stat value. When AppleSmartBattery reported a time
    /// estimate we append it (e.g. "Battery · 3h 12m"); when on AC
    /// while charging we show e.g. "Charging · 42m".
    private func sourceValue(src: BatteryPowerSource) -> String {
        let label = src.displayLabel
        guard src != .acPlugged,
              let seconds = timeRemainingSeconds,
              let formatted = Self.formatRemaining(seconds: seconds) else {
            return label
        }
        return "\(label) · \(formatted)"
    }

    private static func formatRemaining(seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 60 else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private static func healthTint(health: Double, base: Color) -> Color {
        switch health {
        case ..<60: .red
        case ..<80: .orange
        default: base
        }
    }

    private func accessoryStack(level: Double, source: BatteryPowerSource) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    BatteryStatusBadge(source: source, tint: tint)
                    percentageText(level: level, source: source)
                }
                percentageText(level: level, source: source)
            }
            if let temperature, temperature.isFinite {
                Text("\(Int(temperature.rounded()))°C")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Shared accessory text; extracted so both `ViewThatFits`
    /// branches render identical glyphs (otherwise the fits-check
    /// could pick the smaller branch even when the larger would
    /// fit, because differing fonts produce different intrinsic
    /// widths).
    private func percentageText(level: Double, source: BatteryPowerSource) -> some View {
        let isLow = source == .onBattery && level < 20
        return Text("\(level, specifier: "%.0f")%")
            .font(.title3.monospacedDigit().weight(.semibold))
            .foregroundStyle(isLow ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            .contentTransition(.numericText(value: level))
            .animation(.smooth, value: level)
    }

    /// Top-leading status dot colour. Matches Apple's MagSafe LED
    /// convention: amber while charging, green when full (or
    /// charging is paused). `nil` while on battery (no dot).
    private static func cornerDotColor(for source: BatteryPowerSource) -> Color? {
        switch source {
        case .charging: Color(red: 1.00, green: 0.65, blue: 0.10) // amber
        case .acPlugged: Color(red: 0.20, green: 0.80, blue: 0.30) // green
        case .onBattery: nil
        }
    }

    /// Picks the SF Symbol that matches both the current charge
    /// level and whether the user is charging vs. running on
    /// battery. Bolt variants are used while charging so the
    /// symbol itself communicates "I am charging" + "how full I
    /// am" at the same time.
    private static func iconName(for percent: Double, source: BatteryPowerSource) -> String {
        if source == .charging {
            return switch percent {
            case ..<25: "battery.25percent.bolt"
            case ..<50: "battery.50percent.bolt"
            case ..<75: "battery.75percent.bolt"
            default: "battery.100percent.bolt"
            }
        }
        if source == .acPlugged, percent >= 99 {
            return "battery.100percent.bolt"
        }
        return switch percent {
        case ..<10: "battery.0percent"
        case ..<35: "battery.25percent"
        case ..<65: "battery.50percent"
        case ..<90: "battery.75percent"
        default: "battery.100percent"
        }
    }
}
