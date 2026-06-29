//
//  DashboardSystemBanner.swift
//  Peakmon
//
//  Identity strip at the top of the dashboard — an "About this Mac"
//  anchor so the user knows which machine the live numbers belong
//  to (matters on multi-monitor / remote / multi-tenant setups).
//
//  Layout: a Mac icon + model name, then a chip row (chip / RAM /
//  disk / macOS / uptime / serial).
//
//  Identity fields are static for the process lifetime, fetched
//  once via `DeviceInfoReader`. Uptime ticks on its own one-minute
//  schedule (the only value that changes). Serial number is masked
//  by default with a click to reveal — kinder than Activity
//  Monitor's clear display for users who screen-share.
//

import AppKit
import SwiftUI

struct DashboardSystemBanner: View {
    /// Static identity. Reading on init is cheap (~1 ms) and
    /// removes any need for a store/observable.
    private let info: DeviceInfo = DeviceInfoReader.read()

    /// Recomputed every 60s by the timer below — held as state
    /// so the formatted string re-renders without an env hop.
    @State private var uptime: String = "—"

    /// Clicking the SN chip flips this; the formatted value
    /// switches between the masked and full strings.
    @State private var serialRevealed = false

    /// Cached icon for the running machine. Resolved on appear
    /// using the device's marketing name when possible; the
    /// generic "desktopcomputer" SF Symbol is a safe fallback.
    @State private var deviceIcon: NSImage?

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            iconView
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 5) {
                Text(info.modelName)
                    .font(.title3.weight(.semibold))
                chipsRow
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.gray.opacity(0.18), lineWidth: 0.5),
        )
        .task {
            // Initial uptime + one-minute heartbeat via `Task.sleep`
            // (no Timer publisher overhead; auto-cancels on teardown).
            uptime = formatUptime(since: info.bootDate)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                uptime = formatUptime(since: info.bootDate)
            }
        }
        .task {
            deviceIcon = await loadDeviceIcon(modelName: info.modelName)
        }
    }

    // MARK: - Icon

    @ViewBuilder
    private var iconView: some View {
        if let icon = deviceIcon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.tint.opacity(0.15))
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.tint)
            }
        }
    }

    // MARK: - Chips

    private var chipsRow: some View {
        // Plain HStack — the banner is wide enough at every shipped
        // window size that wrapping isn't expected.
        HStack(spacing: 6) {
            chip(icon: "cpu",            tint: .blue,    value: info.chip)
            chip(icon: "memorychip",     tint: .purple,  value: formatRAM(info.memoryBytes))
            chip(icon: "internaldrive",  tint: .green,   value: formatDisk(info.diskBytes))
            chip(icon: "applelogo",      tint: .orange,  value: info.osVersion)
            chip(icon: "clock.arrow.circlepath", tint: .pink, value: "Up \(uptime)")
            serialChip
        }
    }

    /// Standard info chip. All chips share one capsule
    /// treatment so the banner reads as a coherent strip
    /// rather than a row of bespoke widgets.
    private func chip(icon: String, tint: Color, value: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(tint.opacity(0.10), in: .capsule)
        .overlay(Capsule().strokeBorder(tint.opacity(0.15), lineWidth: 0.5))
    }

    /// Serial number chip: tap to toggle masking. The whole
    /// chip is the hit target so the user doesn't have to aim
    /// at the small reveal glyph.
    private var serialChip: some View {
        Button {
            serialRevealed.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: serialRevealed ? "eye" : "eye.slash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.gray)
                Text(serialDisplay)
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.gray.opacity(0.10), in: .capsule)
            .overlay(Capsule().strokeBorder(.gray.opacity(0.15), lineWidth: 0.5))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(serialRevealed ? "Hide serial number" : "Reveal serial number")
    }

    /// SN shown full or masked to the last four characters — enough
    /// to identify the machine without exposing the full serial.
    private var serialDisplay: String {
        guard !info.serialNumber.isEmpty else { return "—" }
        if serialRevealed { return info.serialNumber }
        if info.serialNumber.count <= 4 { return info.serialNumber }
        let suffix = info.serialNumber.suffix(4)
        return "•••• \(suffix)"
    }

    // MARK: - Helpers

    /// Uptime as "7d 4h" / "23m" / "just now". Custom-formatted
    /// (not `DateComponentsFormatter`) to keep the largest two units
    /// only, since "1 d, 4 h, 12 m" is too wide for a chip.
    private func formatUptime(since date: Date) -> String {
        let secs = max(0, Int(Date.now.timeIntervalSince(date)))
        if secs < 60 { return "just now" }
        let mins = secs / 60
        if mins < 60 { return "\(mins)m" }
        let hours = mins / 60
        let leftoverMins = mins % 60
        if hours < 24 { return "\(hours)h \(leftoverMins)m" }
        let days = hours / 24
        let leftoverHours = hours % 24
        return "\(days)d \(leftoverHours)h"
    }

    /// RAM in **binary** units (1 GB = 2³⁰) to match "About This
    /// Mac" and the purchased SKU (a "64 GB" part is 64 × 1024³,
    /// not 68.7 GB in SI).
    private func formatRAM(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / 1_073_741_824
        if gib >= 1024 { return String(format: "%.1f TB", gib / 1024) }
        return String(format: "%.0f GB", gib.rounded())
    }

    /// Storage in **decimal** units (1 GB = 10⁹) snapped up to the
    /// nearest Mac SKU step, so a 1 TB SSD reads "1 TB" not the raw
    /// ~994 GB volume size. Snaps to the first ladder rung within
    /// +10% of raw (the raw-to-SKU gap grows with capacity), else
    /// the smallest rung ≥ raw.
    private func formatDisk(_ bytes: UInt64) -> String {
        let rawGB = Double(bytes) / 1_000_000_000
        let ladder: [Double] = [128, 256, 512, 1024, 2048, 4096, 8192, 16384]
        let snapped = ladder.first { rung in
            rung >= rawGB && rung <= rawGB * 1.10
        } ?? ladder.first { $0 >= rawGB } ?? rawGB

        if snapped >= 1000 {
            return String(format: "%.0f TB", snapped / 1000)
        }
        return String(format: "%.0f GB", snapped)
    }

    /// Resolve a representative Mac icon. `NSComputer` is a public,
    /// long-shipped system icon name; if it's missing we keep the SF
    /// Symbol fallback.
    private func loadDeviceIcon(modelName _: String) async -> NSImage? {
        if let img = NSImage(named: NSImage.Name("NSComputer")) {
            return img
        }
        return nil
    }
}
