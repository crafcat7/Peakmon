//
//  DashboardFormatting.swift
//  Peakmon
//
//  Tiny formatting helpers shared by every dashboard card.
//
//  Extracted from `DashboardView` as static methods so each card
//  view can be a standalone file without dragging the whole
//  dashboard along for the ride, and without each card repeating
//  the same ByteCountFormatter setup.
//

import Foundation

enum DashboardFormatting {
    /// Memory / storage byte counts. Picks MB or GB units; uses
    /// `.memory` count style (1024-base) because that is what
    /// every other macOS UI surface (Activity Monitor, Finder
    /// Get Info) renders.
    static func bytes(_ value: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(value))
    }

    /// Throughput formatter for disk + network rates. Always
    /// suffixes "/s" so the user can tell a 3 MB total apart
    /// from a 3 MB/s rate at a glance.
    static func rate(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .binary
        return "\(formatter.string(fromByteCount: Int64(bytesPerSecond)))/s"
    }

    /// Compact watt formatter shared by the Power card and the
    /// related menu-bar segment. Sub-watt readings (idle SoC)
    /// keep one decimal of precision; once draw exceeds 10 W the
    /// integer part already carries enough resolution and the
    /// decimal just adds noise.
    static func watts(_ watts: Double) -> String {
        let clamped = max(0, watts)
        if clamped < 10 {
            return String(format: "%.1fW", clamped)
        }
        return String(format: "%.0fW", clamped)
    }
}
