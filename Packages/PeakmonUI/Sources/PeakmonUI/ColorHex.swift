//
//  ColorHex.swift
//  PeakmonUI
//
//  Lossless conversion between SwiftUI `Color` and `#RRGGBB` hex
//  strings. Used for persisting per-card tints in `@AppStorage`.
//

import AppKit
import SwiftUI

public extension Color {
    /// Initialise from a `#RRGGBB` or `#RRGGBBAA` hex string. Returns
    /// `nil` if the string cannot be parsed.
    init?(hex: String) {
        var trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }

        guard trimmed.count == 6 || trimmed.count == 8 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: trimmed).scanHexInt64(&value) else { return nil }

        let red, green, blue, alpha: Double
        if trimmed.count == 6 {
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
            alpha = 1
        } else {
            red = Double((value >> 24) & 0xFF) / 255
            green = Double((value >> 16) & 0xFF) / 255
            blue = Double((value >> 8) & 0xFF) / 255
            alpha = Double(value & 0xFF) / 255
        }
        self = Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    /// Serialise to `#RRGGBB`. Alpha is dropped on purpose; the
    /// dashboard tints are always fully opaque.
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let red = Int((ns.redComponent * 255).rounded())
        let green = Int((ns.greenComponent * 255).rounded())
        let blue = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
