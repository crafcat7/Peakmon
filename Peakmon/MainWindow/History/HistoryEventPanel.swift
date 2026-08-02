//
//  HistoryEventPanel.swift
//  Peakmon
//
//  Shared anomaly presentation for History and Dashboard.
//

import PeakmonCore
import PeakmonUI
import SwiftUI

struct HistoryEventPanel: View {
    let events: [HistoryAnomalyEvent]
    let supportsAnomalies: Bool
    let focusedEventID: UUID?

    private var orderedEvents: [HistoryAnomalyEvent] {
        events.sorted {
            if $0.severity != $1.severity {
                return $0.severity > $1.severity
            }
            return $0.startDate > $1.startDate
        }
    }

    @ViewBuilder
    var body: some View {
        if events.isEmpty {
            compactEmptyPanel
        } else {
            expandedPanel
        }
    }

    private var compactEmptyPanel: some View {
        HStack(spacing: 10) {
            Text("Anomalies")
                .font(.headline)
                .lineLimit(1)

            if supportsAnomalies {
                countBadge
            }

            Spacer(minLength: 12)

            Text(LocalizedStringKey(supportsAnomalies ? "No anomalies in this range" : "Not monitored for anomalies"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .peakmonGlassSurface()
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.gray.opacity(0.18), lineWidth: 0.5)
        }
    }

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Anomalies")
                    .font(.headline)
                Spacer()
                countBadge
            }

            VStack(spacing: 0) {
                ForEach(Array(orderedEvents.enumerated()), id: \.element.id) { index, event in
                    HistoryEventRow(
                        event: event,
                        isFocused: event.id == focusedEventID,
                    )
                    .id(event.id)
                    if index < orderedEvents.count - 1 {
                        Divider().opacity(0.5)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .peakmonGlassSurface()
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.gray.opacity(0.18), lineWidth: 0.5)
        }
    }

    private var countBadge: some View {
        Text("\(events.count)")
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: .capsule)
    }
}

private struct HistoryEventRow: View {
    let event: HistoryAnomalyEvent
    let isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.kind.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(event.severity.tint)
                .padding(7)
                .background(event.severity.tint.opacity(0.14), in: .rect(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    HStack(spacing: 8) {
                        Text(LocalizedStringKey(event.kind.title))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(LocalizedStringKey(event.severity.title))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(event.severity.tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(event.severity.tint.opacity(0.12), in: .capsule)
                    }

                    Spacer(minLength: 16)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(LocalizedStringKey(peakValueText))
                            .font(.callout.monospacedDigit().weight(.medium))
                            .lineLimit(1)
                        Text(timeRange)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Text(event.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !event.processes.isEmpty {
                    processAttribution
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 11)
        .background(
            isFocused ? Color.primary.opacity(0.025) : Color.clear,
            in: .rect(cornerRadius: 9),
        )
        .overlay(alignment: .leading) {
            if isFocused {
                Capsule()
                    .fill(event.severity.tint.opacity(0.72))
                    .frame(width: 3)
                    .padding(.vertical, 10)
            }
        }
    }

    private var timeRange: String {
        let start = event.startDate.formatted(date: .omitted, time: .shortened)
        let end = event.endDate.formatted(date: .omitted, time: .shortened)
        return "\(start) - \(end)"
    }

    private var processAttribution: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                processAttributionLabel

                ForEach(Array(event.processes.prefix(3))) { process in
                    processChip(process)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                processAttributionLabel
                Text(processSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 8))
    }

    private var processAttributionLabel: some View {
        Label("Possible causes", systemImage: "person.2.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private func processChip(_ process: HistoryAnomalyProcessSnapshot) -> some View {
        HStack(spacing: 5) {
            Text(process.name)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(processMetric(process))
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.background.opacity(0.72), in: .capsule)
        .overlay {
            Capsule()
                .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
    }

    private var processSummary: String {
        event.processes.prefix(3).map { process in
            "\(process.name)  \(processMetric(process))"
        }
        .joined(separator: "   ·   ")
    }

    private func processMetric(_ process: HistoryAnomalyProcessSnapshot) -> String {
        switch event.kind {
        case .memoryPressure, .memorySwapHigh:
            DashboardFormatting.bytesShort(Double(process.memoryBytes))
        default:
            "\(Int(process.cpuPercent.rounded()))% CPU"
        }
    }

    private var peakValueText: String {
        if event.metricKind == .memoryPressureLevel {
            return memoryPressureLabel(Int(event.peakValue))
        }
        return formatMetricValue(event.peakValue, unit: event.unit)
    }
}

extension HistoryAnomalyKind {
    var title: String {
        switch self {
        case .cpuSustainedHigh: "CPU sustained high"
        case .gpuSustainedHigh: "GPU sustained high"
        case .memoryPressure: "Memory pressure"
        case .memorySwapHigh: "Swap elevated"
        case .powerSustainedHigh: "Power sustained high"
        case .diskReadSustainedHigh: "Disk read sustained"
        case .diskWriteSustainedHigh: "Disk write sustained"
        case .networkInSustainedHigh: "Network receive sustained"
        case .networkOutSustainedHigh: "Network send sustained"
        case .thermalCPUHigh: "CPU thermal high"
        case .thermalGPUHigh: "GPU thermal high"
        }
    }

    var systemImage: String {
        switch self {
        case .cpuSustainedHigh: "cpu"
        case .gpuSustainedHigh: "cpu.fill"
        case .memoryPressure: "memorychip"
        case .memorySwapHigh: "arrow.left.arrow.right"
        case .powerSustainedHigh: "bolt.fill"
        case .diskReadSustainedHigh, .diskWriteSustainedHigh: "internaldrive"
        case .networkInSustainedHigh, .networkOutSustainedHigh: "network"
        case .thermalCPUHigh, .thermalGPUHigh: "thermometer.medium"
        }
    }
}

extension HistoryAnomalySeverity {
    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    var tint: Color {
        switch self {
        case .low: .yellow
        case .medium: .orange
        case .high: .red
        }
    }
}

func formatMetricValue(_ value: Double?, unit: MetricUnit) -> String {
    guard let value else { return "--" }
    switch unit {
    case .percent, .ratio:
        return String(format: "%.0f%%", value)
    case .bytes:
        return DashboardFormatting.bytesShort(value)
    case .bytesPerSecond:
        return DashboardFormatting.rateShort(value)
    case .count:
        return String(format: "%.0f", value)
    case .watts:
        return DashboardFormatting.wattsChip(value)
    case .celsius:
        return "\(Int(value.rounded()))°C"
    case .rpm:
        return String(format: "%.0f rpm", value)
    }
}

func durationText(_ interval: TimeInterval?) -> String {
    guard let interval else { return "--" }
    let seconds = max(0, Int(interval.rounded()))
    if seconds < 60 {
        return "\(seconds)s"
    }
    let minutes = seconds / 60
    if minutes < 60 {
        return "\(minutes)m"
    }
    let hours = minutes / 60
    let remainder = minutes % 60
    if remainder == 0 {
        return "\(hours)h"
    }
    return "\(hours)h \(remainder)m"
}

func memoryPressureLabel(_ level: Int) -> String {
    switch level {
    case 2: "Warning"
    case 4: "Urgent"
    case 8: "Critical"
    default: "Normal"
    }
}
