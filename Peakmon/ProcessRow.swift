//
//  ProcessRow.swift
//  Peakmon
//
//  Single row inside the Top Processes card. Renders the process
//  name, its CPU% (or memory footprint when the user has chosen the
//  RAM-sorted variant), and a slim utilisation bar so the eye can
//  rank rows without parsing the digits.
//
//  Kept separate from `DashboardView.swift` so each file stays under
//  SwiftLint's `file_length` ceiling.
//

import PeakmonCore
import SwiftUI

struct ProcessRow: View {
    let snapshot: ProcessSnapshot
    /// When true, the right-hand metric and bar are driven by
    /// `memoryBytes` instead of `cpuPercent`. Driven by the user's
    /// "Sort by RAM" toggle in Display settings.
    let showMemory: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(snapshot.name)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(metricText)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .contentShape(.rect)
        .help("PID \(snapshot.pid) — \(detailedTooltip)")
    }

    private var metricText: String {
        if showMemory {
            return DashboardFormatting.bytesShort(Double(snapshot.memoryBytes))
        }
        // Activity Monitor convention: % of one core, can exceed 100.
        if snapshot.cpuPercent >= 100 {
            return String(format: "%.0f%%", snapshot.cpuPercent)
        }
        return String(format: "%.1f%%", snapshot.cpuPercent)
    }

    private var detailedTooltip: String {
        let cpu = String(format: "%.1f%% CPU", snapshot.cpuPercent)
        let ram = DashboardFormatting.bytesShort(Double(snapshot.memoryBytes)) + " RAM"
        return "\(cpu) · \(ram)"
    }

}
