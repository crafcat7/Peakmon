//
//  BatteryCard.swift
//  Peakmon
//
//  Dashboard battery card: percentage + temperature accessory,
//  power-source badge, charging/AC corner dot, Smart Battery health
//  facts, and a sparkline of the charge history pulled from
//  `batteryLevel`.
//

import PeakmonCore
import PeakmonUI
import SwiftUI

struct BatteryCard: View {
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

    var body: some View {
        let level = sample?.value ?? 0
        let src = source
        let isLow = src == .onBattery && level < 20
        let iconTint: Color = isLow ? .red : tint
        let iconName = isLow ? "battery.0percent" : Self.iconName(for: level, source: src)

        DashboardCardTemplate(
            title: "Battery",
            systemImage: iconName,
            tint: iconTint,
            stats: batteryStats(source: src),
            accessory: {
                accessoryStack(level: level, source: src)
            },
            chart: {
                MetricSparklineView(
                    samples: store.history(for: .batteryLevel),
                    style: .battery,
                )
            },
        )
        .overlay(alignment: .topLeading) {
            if let dotColor = Self.cornerDotColor(for: src) {
                BatteryCornerDot(color: dotColor)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: src)
    }

    /// Builds the stats row. Always shows Source; appends Health
    /// and Cycles when AppleSmartBattery exposed them.
    /// Time-remaining is folded into the Source stat as a secondary
    /// line because the template's stat layout is single-value-per-
    /// block. Temperature lives under the percentage accessory to
    /// match CPU/GPU popover cards.
    private func batteryStats(source src: BatteryPowerSource) -> [CardStat] {
        var stats: [CardStat] = []
        stats.append(CardStat(
            label: "Source",
            value: sourceValue(src: src),
            tint: tint,
        ))
        if let health {
            stats.append(CardStat(
                label: "Health",
                value: String(format: "%.0f%%", health),
                tint: Self.healthTint(health: health, base: tint),
            ))
        }
        if let cycles {
            stats.append(CardStat(
                label: "Cycles",
                value: "\(cycles)",
                tint: tint,
            ))
        }
        return stats
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
