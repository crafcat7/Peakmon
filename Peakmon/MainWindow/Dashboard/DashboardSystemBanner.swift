//
//  DashboardSystemBanner.swift
//  Peakmon
//
//  Identity strip at the top of the dashboard — an "About this Mac"
//  anchor so the user knows which machine the live numbers belong
//  to (matters on multi-monitor / remote / multi-tenant setups).
//
//  Layout: a compact identity block followed by a segmented system
//  status rail (chip / RAM / disk / macOS / uptime). This borrows
//  the scan rhythm of workstation dashboards without repeating the
//  live CPU / GPU / memory values already present in metric cards.
//
//  Identity fields are static for the process lifetime, fetched
//  once via `DeviceInfoReader`. Uptime ticks on its own one-minute
//  schedule (the only value that changes). Serial number is masked
//  by default with a click to reveal — kinder than Activity
//  Monitor's clear display for users who screen-share.
//

import AppKit
import PeakmonCore
import PeakmonUI
import SwiftUI

struct DashboardSystemBanner: View {
    let onShowHistory: (HistoryAnomalyEvent?) -> Void

    @Environment(HistoryIssuesStore.self) private var issuesStore

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
        ViewThatFits(in: .horizontal) {
            wideStatusRail
            compactStatusRail
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .peakmonGlassSurface(cornerRadius: 12)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
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

    // MARK: - Status rail

    /// At workstation widths the banner becomes a single scan line,
    /// matching the reference dashboard's strongest hierarchy. The
    /// values describe the machine rather than repeating card data.
    private var wideStatusRail: some View {
        HStack(alignment: .center, spacing: 0) {
            identityBlock
            railDivider
            statusFact(icon: "cpu", label: "Chip", value: compactChipName, tint: .blue)
            railDivider
            statusFact(icon: "memorychip", label: "Memory", value: formatRAM(info.memoryBytes), tint: .purple)
            railDivider
            statusFact(icon: "internaldrive", label: "Storage", value: formatDisk(info.diskBytes), tint: .green)
            railDivider
            statusFact(icon: "applelogo", label: "System", value: info.osVersion, tint: .orange)
            railDivider
            statusFact(icon: "clock.arrow.circlepath", label: "Uptime", value: uptime, tint: .pink)

            Spacer(minLength: 16)
            healthStatus
        }
    }

    /// The narrower form keeps the same visual language but limits
    /// the secondary facts so the health action remains reachable.
    private var compactStatusRail: some View {
        HStack(alignment: .center, spacing: 12) {
            identityBlock

            Spacer(minLength: 8)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    compactFact(icon: "memorychip", value: formatRAM(info.memoryBytes), tint: .purple)
                    compactFact(icon: "clock.arrow.circlepath", value: uptime, tint: .pink)
                }
                compactFact(icon: "clock.arrow.circlepath", value: uptime, tint: .pink)
            }

            healthStatus
        }
    }

    private var identityBlock: some View {
        HStack(spacing: 10) {
            iconView
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(info.modelName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Button {
                    serialRevealed.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text(info.modelIdentifier)
                        Text("·")
                        Image(systemName: serialRevealed ? "eye" : "eye.slash")
                        Text(serialDisplay)
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(serialRevealed ? "Hide serial number" : "Reveal serial number")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var railDivider: some View {
        Divider()
            .frame(height: 34)
            .padding(.horizontal, 12)
    }

    private func statusFact(icon: String, label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tint)
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.45)
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func compactFact(icon: String, value: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var compactChipName: String {
        info.chip.components(separatedBy: " · ").first ?? info.chip
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

    // MARK: - Health

    private var latestEvent: HistoryAnomalyEvent? {
        issuesStore.recentEvents.first
    }

    private var healthTint: Color {
        latestEvent?.severity.tint ?? .green
    }

    private var healthStatus: some View {
        Button {
            onShowHistory(latestEvent)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: latestEvent == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(healthTint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(latestEvent == nil ? "All systems normal" : latestEvent?.kind.title ?? "Recent issue")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(latestEvent == nil ? "No anomalies in the last hour" : healthDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(healthTint.opacity(0.09), in: .rect(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(healthTint.opacity(0.18), lineWidth: 0.5)
            }
            .contentShape(.rect(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help("View health history")
    }

    private var healthDetail: String {
        guard let latestEvent else { return "" }
        if issuesStore.recentEvents.count > 1 {
            return "\(issuesStore.recentEvents.count) recent issues"
        }
        return latestEvent.reason
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
