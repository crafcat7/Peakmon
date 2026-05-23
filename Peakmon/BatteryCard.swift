//
//  BatteryCard.swift
//  Peakmon
//
//  Dashboard battery card: percentage accessory, power-source
//  badge, charging/AC corner dot, and a sparkline of the charge
//  history pulled from `batteryLevel`.
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
            stats: [
                CardStat(label: "Source", value: src.displayLabel, tint: tint),
            ],
            accessory: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        BatteryStatusBadge(source: src, tint: tint)
                        percentageText(level: level, source: src)
                    }
                    percentageText(level: level, source: src)
                }
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
