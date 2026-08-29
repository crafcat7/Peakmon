//
//  MenuBarPercentFormatting.swift
//  PeakmonUI
//
//  Shared formatting and sizing for the fixed-width percentage value used
//  by Peakmon's menu-bar segments.
//

import Foundation
import SwiftUI

/// Formatting for a menu-bar percentage value.
public enum MenuBarPercentFormatting {
    /// Format a percentage with the same integer rounding used by the
    /// menu-bar value column.
    public static func string(for value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}

/// A percentage value whose layout is fixed by a hidden three-digit
/// reference text. The reference remains in the view hierarchy so SwiftUI
/// reserves the intrinsic width of `100%` for every value (`9%`, `99%`, and
/// `100%` therefore occupy the same column), while `.hidden()` keeps it out
/// of the rendered pixels. The width follows the inherited menu-bar font and
/// does not require AppKit font measurement or a scale-dependent padding
/// constant.
public struct MenuBarPercentValue: View {
    /// A three-digit reference exercises the maximum supported digit count;
    /// monospaced digits give every three-digit percentage the same advance.
    public static let referenceText = "100%"

    private let text: String

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        ZStack(alignment: .trailing) {
            Text(Self.referenceText)
                .hidden()
                .accessibilityHidden(true)
            Text(text)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
