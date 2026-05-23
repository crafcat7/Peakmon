//
//  BatteryCardEffects.swift
//  Peakmon
//
//  Visual effects that decorate the Dashboard battery card based on
//  the current `BatteryPowerSource` and level. Each state gets its
//  own distinct treatment so the user can identify power state at a
//  glance without reading the label.
//
//  - .charging:  animated horizontal "current flow" sweep
//  - .acPlugged: steady standby indicator dot (top-leading)
//  - .onBattery: slow red breathing border when level < 20 %
//

import SwiftUI

// MARK: - Charging flow overlay

/// A horizontal gradient highlight that sweeps left-to-right across
/// the card to suggest electric current entering the battery.
/// Driven by `TimelineView` so the animation keeps running while the
/// popover is open without forcing the whole card to re-render.
struct ChargingFlowOverlay: View {
    let tint: Color
    var period: Double = 2.4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let phase = (context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period)) / period
            GeometryReader { proxy in
                let width = proxy.size.width
                let bandWidth = max(width * 0.35, 60)
                let xPos = -bandWidth + (width + bandWidth * 2) * phase

                LinearGradient(
                    colors: [
                        tint.opacity(0),
                        tint.opacity(0.35),
                        Color.white.opacity(0.55),
                        tint.opacity(0.35),
                        tint.opacity(0),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing,
                )
                .frame(width: bandWidth, height: proxy.size.height)
                .offset(x: xPos)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
            }
        }
        .clipShape(.rect(cornerRadius: 12))
        .allowsHitTesting(false)
    }
}

// MARK: - Standby indicator

/// A small steady dot in the top-leading corner. Subtle and static,
/// communicating "plugged in, idle" — analogous to the green LED on
/// a charger that has finished topping off.
struct StandbyIndicator: View {
    let tint: Color

    var body: some View {
        Circle()
            .fill(tint.opacity(0.9))
            .frame(width: 6, height: 6)
            .shadow(color: tint.opacity(0.6), radius: 3)
            .padding(.top, 10)
            .padding(.leading, 10)
            .allowsHitTesting(false)
    }
}

// MARK: - Low-battery breathing border

/// Pulses a red border around the card when the host is on battery
/// and below the supplied `threshold`. The animation period is long
/// (2 s) so it reads as "warning" rather than "alarm".
struct LowBatteryPulse: View {
    let level: Double
    var threshold: Double = 20
    var period: Double = 2.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: level >= threshold)) { context in
            let phase = (context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period)) / period
            let pulse = (sin(phase * 2 * .pi) + 1) / 2 // 0...1
            let opacity = level < threshold ? 0.25 + pulse * 0.45 : 0

            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.red.opacity(opacity), lineWidth: 1.2)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Battery corner dot

/// Solid corner dot with a soft glow. Hosted as a top-leading
/// overlay on the battery card. Replaces the older animated
/// `ChargingFlowOverlay` / `StandbyIndicator` / `LowBatteryPulse`
/// treatments in a later refactor.
struct BatteryCornerDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .shadow(color: color.opacity(0.6), radius: 2)
            .padding(.top, 10)
            .padding(.leading, 10)
            .allowsHitTesting(false)
    }
}
