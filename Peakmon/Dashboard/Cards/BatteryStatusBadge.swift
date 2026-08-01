//
//  BatteryStatusBadge.swift
//  Peakmon
//
//  A compact pill that surfaces the current `BatteryPowerSource`
//  next to the battery percentage. Designed for use inside the
//  Dashboard battery card accessory slot.
//

import PeakmonCore
import SwiftUI

struct BatteryStatusBadge: View {
    let source: BatteryPowerSource
    let tint: Color

    var body: some View {
        // `ViewThatFits` lets the badge gracefully degrade in the
        // narrow half-width card layout: when the icon+label capsule
        // can't fit alongside the battery percentage, we fall back to
        // an icon-only capsule instead of letting SwiftUI truncate
        // the label or push the percentage off the row.
        ViewThatFits(in: .horizontal) {
            iconAndLabel
            iconOnly
        }
        .foregroundStyle(foregroundColor)
        .background(backgroundColor, in: .capsule)
        .overlay {
            Capsule().stroke(borderColor, lineWidth: 0.5)
        }
        .help(source.displayLabel)
    }

    private var iconAndLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: source.systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(LocalizedStringKey(source.displayLabel))
                .font(.system(size: 10, weight: .semibold))
                .fixedSize()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
    }

    private var iconOnly: some View {
        Image(systemName: source.systemImage)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
    }

    private var foregroundColor: Color {
        switch source {
        case .charging: tint
        case .acPlugged: .secondary
        case .onBattery: .secondary
        }
    }

    private var backgroundColor: Color {
        switch source {
        case .charging: tint.opacity(0.15)
        case .acPlugged: Color.gray.opacity(0.12)
        case .onBattery: Color.gray.opacity(0.10)
        }
    }

    private var borderColor: Color {
        switch source {
        case .charging: tint.opacity(0.35)
        case .acPlugged: Color.gray.opacity(0.25)
        case .onBattery: Color.gray.opacity(0.20)
        }
    }
}
