//
//  BatteryCardEffects.swift
//  Peakmon
//
//  Battery card decoration. A single small dot in the card's
//  top-leading corner conveys the live power-source state:
//
//  - .charging:  the dot lights up in the user's battery tint,
//                with a soft glow — analogous to the green LED
//                on a wall charger that says "current is flowing".
//  - .acPlugged: the dot stays present but desaturated (a quiet
//                grey) — "connected, idle".
//  - .onBattery: no dot.
//
//  The dot is static — no animation — so it follows Apple's
//  restrained motion language. Low-battery state is communicated
//  separately by switching the SF battery symbol to its
//  `battery.0percent` variant and tinting both icon and percentage
//  text red in `DashboardView`.
//

import SwiftUI

/// Solid corner dot with a soft glow. Hosted as a top-leading
/// overlay on the battery card.
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
