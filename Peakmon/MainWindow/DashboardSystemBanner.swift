//
//  DashboardSystemBanner.swift
//  Peakmon
//
//  Identity strip that sits at the very top of the dashboard
//  surface, above the metric card grid. Acts as the
//  "About this Mac" anchor for the user so they can
//  remember at a glance *which* machine the live numbers
//  underneath belong to (matters on multi-monitor / remote-
//  desktop / multi-tenant setups).
//
//  Visual structure:
//
//    ┌──────────────────────────────────────────────────────┐
//    │  [Mac icon]  Model name · model id                  │
//    │              Chip · RAM · Disk · macOS · Uptime · SN│
//    └──────────────────────────────────────────────────────┘
//
//  Identity fields are static for the life of the process,
//  fetched once via `DeviceInfoReader`. Uptime ticks on its
//  own one-minute Timer because it's the only value that
//  changes over time; sub-minute precision isn't useful on a
//  banner field that mostly reads "37 days".
//
//  Serial number is masked by default ("C02···K9XYZ") with a
//  click toggle to reveal — Activity Monitor shows it in the
//  clear but enough users mirror their screen on calls that
//  defaulting to masked is the kinder choice.
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
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 6) {
                Text(info.modelName)
                    .font(.title3.weight(.semibold))
                chipsRow
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.gray.opacity(0.18), lineWidth: 0.5),
        )
        .task {
            // Initial uptime + one-minute heartbeat. We use
            // `Task.sleep` rather than a Timer to avoid the
            // Combine/Timer publisher overhead and to make
            // cancellation automatic when the view goes away.
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
        // `FlexibleStack` would be ideal but stock SwiftUI lacks
        // one, so we use an HStack and clip with `.layoutPriority`
        // ordering. The banner is wide enough on every dashboard
        // window size we ship that wrapping isn't expected.
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
        .padding(.vertical, 5)
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
            .padding(.vertical, 5)
            .background(.gray.opacity(0.10), in: .capsule)
            .overlay(Capsule().strokeBorder(.gray.opacity(0.15), lineWidth: 0.5))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(serialRevealed ? "Hide serial number" : "Reveal serial number")
    }

    /// Renders the SN either fully or masked, keeping the
    /// last four characters visible so the user has enough
    /// to identify the machine without exposing the unique
    /// prefix that pairs with their Apple ID purchases.
    private var serialDisplay: String {
        guard !info.serialNumber.isEmpty else { return "—" }
        if serialRevealed { return info.serialNumber }
        if info.serialNumber.count <= 4 { return info.serialNumber }
        let suffix = info.serialNumber.suffix(4)
        return "•••• \(suffix)"
    }

    // MARK: - Helpers

    /// Human uptime ("7d 4h", "23m", "just now"). We avoid
    /// `DateComponentsFormatter`'s `.short` style because it
    /// produces "1 d, 4 h, 12 m" which is too wide for a chip;
    /// the custom formatter keeps the largest two units only.
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

    /// RAM uses **binary** units (1 GB = 2³⁰ bytes) to match
    /// what Apple's "About This Mac" panel prints and what the
    /// user actually purchased (a "64 GB" SKU is 64 × 1024³
    /// bytes, not 64 × 10⁹). Reporting it as 68.7 GB by using
    /// SI here would be technically correct and practically
    /// confusing.
    private func formatRAM(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / 1_073_741_824
        if gib >= 1024 { return String(format: "%.1f TB", gib / 1024) }
        return String(format: "%.0f GB", gib.rounded())
    }

    /// Storage uses **decimal** units (1 GB = 10⁹ bytes) and
    /// is **snapped to the nearest SKU step** so a 1 TB SSD
    /// reads "1 TB" instead of "994 GB". `FileManager`'s raw
    /// number is the user-visible volume size — already net
    /// of the EFI/recovery/preboot partitions — so on a 1 TB
    /// drive it lands at ~994 GB, which is correct but not
    /// what a buyer recognises.
    ///
    /// We round up to the nearest entry in the canonical Mac
    /// storage ladder (128 / 256 / 512 / 1024 / 2048 / 4096 /
    /// 8192 GB). The tolerance window is 10% upward — wider
    /// than necessary because the gap between raw and SKU
    /// grows with capacity (≈6% on 1 TB, ≈3% on 2 TB), and we
    /// would rather snap than miss.
    private func formatDisk(_ bytes: UInt64) -> String {
        let rawGB = Double(bytes) / 1_000_000_000
        let ladder: [Double] = [128, 256, 512, 1024, 2048, 4096, 8192, 16384]
        // First ladder entry that's within +10% of raw, or
        // the smallest entry ≥ raw — whichever comes first.
        let snapped = ladder.first { rung in
            rung >= rawGB && rung <= rawGB * 1.10
        } ?? ladder.first { $0 >= rawGB } ?? rawGB

        if snapped >= 1000 {
            return String(format: "%.0f TB", snapped / 1000)
        }
        return String(format: "%.0f GB", snapped)
    }

    /// Resolve a representative app icon for the device.
    /// Strategy: look up the Apple-bundled "About This Mac" /
    /// system "Mac" icon via `NSImage(named:)` — these symbol
    /// names are public and have shipped for years. If none
    /// of them exist on this OS, we leave the SF Symbol
    /// fallback in place.
    private func loadDeviceIcon(modelName _: String) async -> NSImage? {
        // `NSImage.Name.computer` is one of the few public,
        // documented system icon names that resolves to the
        // generic Mac silhouette across macOS versions.
        if let img = NSImage(named: NSImage.Name("NSComputer")) {
            return img
        }
        return nil
    }
}

#Preview {
    DashboardSystemBanner()
        .frame(width: 1000)
        .padding()
}
