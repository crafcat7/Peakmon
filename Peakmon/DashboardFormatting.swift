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
import SwiftUI

enum DashboardFormatting {
    // MARK: - Cached formatters

    private static let bytesFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB]
        f.countStyle = .memory
        return f
    }()

    private static let rateFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .binary
        return f
    }()

    // MARK: - Popover card formatters

    /// Memory / storage byte counts. Picks MB or GB units; uses
    /// `.memory` count style (1024-base) because that is what
    /// every other macOS UI surface (Activity Monitor, Finder
    /// Get Info) renders.
    static func bytes(_ value: Double) -> String {
        bytesFormatter.string(fromByteCount: Int64(value))
    }

    /// Throughput formatter for disk + network rates. Always
    /// suffixes "/s" so the user can tell a 3 MB total apart
    /// from a 3 MB/s rate at a glance.
    static func rate(_ bytesPerSecond: Double) -> String {
        "\(rateFormatter.string(fromByteCount: Int64(bytesPerSecond)))/s"
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

    // MARK: - Main window card formatters

    /// Headline byte count: one decimal above 1 GB, integer MB
    /// below. Used by Memory card headline and Disk card capacity.
    static func bytesHeadline(_ bytes: Double) -> String {
        let gb = bytes / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = bytes / 1_048_576
        return String(format: "%.0f MB", mb)
    }

    /// Compact byte count for chips and breakdown rows. Integer
    /// GB at 10+, one decimal below 10 GB, integer MB below 1 GB.
    /// Includes TB for large drives.
    static func bytesShort(_ bytes: Double) -> String {
        let gb = bytes / 1_073_741_824
        if gb >= 1000 { return String(format: "%.1f TB", gb / 1024) }
        if gb >= 10 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = bytes / 1_048_576
        return String(format: "%.0f MB", mb)
    }

    /// Headline rate: one decimal for MB/s, integer KB/s below
    /// 1 MB/s. Includes high-throughput integer MB/s above 100.
    static func rateHeadline(_ bps: Double) -> String {
        let mbps = bps / 1_048_576
        if mbps >= 100 { return String(format: "%.0f MB/s", mbps) }
        if mbps >= 1 { return String(format: "%.1f MB/s", mbps) }
        let kbps = bps / 1024
        return String(format: "%.0f KB/s", kbps)
    }

    /// Short rate for chips and footer slots: one decimal for
    /// MB/s, integer KB/s below 1 MB/s.
    static func rateShort(_ bps: Double) -> String {
        let mbps = bps / 1_048_576
        if mbps >= 1 { return String(format: "%.1f MB/s", mbps) }
        let kbps = bps / 1024
        return String(format: "%.0f KB/s", kbps)
    }

    /// Watt value for chips: one decimal always.
    static func wattsChip(_ watts: Double) -> String {
        String(format: "%.1f W", watts)
    }

    /// Watt value for rail breakdown rows: two decimal places.
    static func wattsRail(_ watts: Double) -> String {
        String(format: "%.2f W", watts)
    }

    /// Dynamic colour for temperature readings. Transitions
    /// through cool → warm → hot thresholds matching the
    /// semantic palette used by CPU and GPU dashboard cards.
    static func temperatureColor(_ celsius: Double) -> Color {
        if celsius < 60 { return .secondary }
        if celsius < 80 { return .primary }
        if celsius < 95 { return .yellow }
        return .red
    }

    /// Battery packs should be treated as warm much earlier than
    /// CPU/GPU dies. Keep normal room-temperature operation quiet,
    /// then call out sustained charging / hot chassis conditions.
    static func batteryTemperatureColor(_ celsius: Double) -> Color {
        if celsius < 35 { return .secondary }
        if celsius < 40 { return .primary }
        if celsius < 45 { return .yellow }
        return .red
    }

    /// Dynamic colour for per-process CPU usage bars. Mirrors
    /// the thresholds used by Activity Monitor's CPU column.
    static func cpuTint(_ cpu: Double) -> Color {
        if cpu < 10 { return .secondary }
        if cpu < 50 { return .primary }
        if cpu < 150 { return .orange }
        return .red
    }
}
