//
//  MenuBarPreview.swift
//  Peakmon
//
//  Settings-page widgets that visualise the user's `MenuBarSegment`
//  selection: a live pill that mimics the system status bar, plus a
//  checkbox row used inside the segment list.
//

import PeakmonCore
import SwiftUI

/// Renders the live menu bar label inside a dark pill so the user
/// sees exactly what their selection looks like in the system bar.
struct MenuBarLivePreview: View {
    let segments: [MenuBarSegment]
    let store: MetricsStore

    @CardTintStorage(.cpu) private var cpuTint
    @CardTintStorage(.memory) private var memoryTint
    @CardTintStorage(.disk) private var diskTint
    @CardTintStorage(.network) private var networkTint

    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            content
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(
                    LinearGradient(
                        colors: [Color.black.opacity(0.9), Color.black.opacity(0.75)],
                        startPoint: .top,
                        endPoint: .bottom,
                    ),
                    in: .capsule,
                )
                .overlay {
                    Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                }
            Spacer()
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(
            Color.gray.opacity(0.08),
            in: .rect(cornerRadius: 8),
        )
    }

    @ViewBuilder
    private var content: some View {
        if segments.isEmpty {
            Text("Peakmon")
                .foregroundStyle(.white.opacity(0.85))
                .font(.system(size: 12, weight: .medium))
        } else {
            HStack(spacing: 4) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    if index > 0 {
                        Text("|").foregroundStyle(.white.opacity(0.45))
                    }
                    segmentView(segment)
                }
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: MenuBarSegment) -> some View {
        switch segment {
        case .cpuPercent:
            let cpu = store.latest(for: .cpuTotal)?.value ?? 0
            Text("CPU \(Int(cpu.rounded()))%")
        case .cpuGraph:
            HStack(spacing: 3) {
                Text("CPU")
                MenuBarBarChart(samples: store.history(for: .cpuTotal), tint: cpuTint)
            }
        case .memoryPercent:
            let mem = store.latest(for: .memoryPressure)?.value ?? 0
            Text("MEM \(Int(mem.rounded()))%")
        case .memoryGraph:
            HStack(spacing: 3) {
                Text("MEM")
                MenuBarBarChart(samples: store.history(for: .memoryPressure), tint: memoryTint)
            }
        case .networkRate:
            let down = store.latest(for: .netInRate)?.value ?? 0
            let up = store.latest(for: .netOutRate)?.value ?? 0
            Text("↓\(Self.shortRate(down)) ↑\(Self.shortRate(up))")
        case .networkGraph:
            HStack(spacing: 3) {
                Text("NET")
                MenuBarBarChart(
                    samples: Self.combinedHistory(store: store, kindA: .netInRate, kindB: .netOutRate),
                    tint: networkTint,
                    maxValue: nil,
                )
            }
        case .diskRate:
            let read = store.latest(for: .diskReadRate)?.value ?? 0
            let write = store.latest(for: .diskWriteRate)?.value ?? 0
            Text("R\(Self.shortRate(read)) W\(Self.shortRate(write))")
        case .diskGraph:
            HStack(spacing: 3) {
                Text("DISK")
                MenuBarBarChart(
                    samples: Self.combinedHistory(store: store, kindA: .diskReadRate, kindB: .diskWriteRate),
                    tint: diskTint,
                    maxValue: nil,
                )
            }
        case .batteryPercent:
            batteryPercentView
        }
    }

    @ViewBuilder
    private var batteryPercentView: some View {
        let pct = store.latest(for: .batteryLevel)?.value ?? 0
        let source = store.latest(for: .batteryPowerSource).map {
            BatteryPowerSource(metricValue: $0.value)
        } ?? .onBattery
        HStack(spacing: 2) {
            Text("BAT \(Int(pct.rounded()))%")
            if source == .charging {
                Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold))
            } else if source == .acPlugged {
                Image(systemName: "powerplug.fill").font(.system(size: 9, weight: .semibold))
            }
        }
    }

    private static func shortRate(_ bytesPerSecond: Double) -> String {
        let kib = bytesPerSecond / 1024
        if kib < 1 { return "0K" }
        if kib < 1024 { return "\(Int(kib))K" }
        let mib = kib / 1024
        if mib < 10 { return String(format: "%.1fM", mib) }
        return "\(Int(mib))M"
    }

    private static func combinedHistory(
        store: MetricsStore,
        kindA: MetricKind,
        kindB: MetricKind,
    ) -> [MetricSample] {
        let lhs = store.history(for: kindA)
        let rhs = store.history(for: kindB)
        let count = min(lhs.count, rhs.count)
        guard count > 0 else { return [] }
        return (0 ..< count).map { index in
            let left = lhs[lhs.count - count + index]
            let right = rhs[rhs.count - count + index]
            return MetricSample(
                kind: kindA,
                unit: left.unit,
                value: left.value + right.value,
                timestamp: left.timestamp,
            )
        }
    }
}

/// A checkbox row representing a single segment option. Displays an
/// optional drag handle (`line.3.horizontal`) when the row lives in a
/// reorderable list.
struct MenuBarSegmentRow: View {
    let segment: MenuBarSegment
    let isSelected: Bool
    var showsDragHandle: Bool = false
    let onToggle: () -> Void

    @State private var isHovering = false
    @State private var isHandleHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "minus.circle.fill" : "plus.circle.fill")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(isSelected ? Color.red.opacity(0.85) : Color.accentColor)
                        .frame(width: 22)

                    Image(systemName: segment.systemImage)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)

                    Text(segment.title)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)

                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if showsDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isHandleHovering ? .primary : .tertiary)
                    .padding(.horizontal, 4)
                    .onHover { isHandleHovering = $0 }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .background(
            isHovering ? Color.primary.opacity(0.06) : Color.clear,
        )
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }
}

/// A titled, bordered container that hosts segment rows. Layout is a
/// plain `VStack + ForEach` (no `List`) so there is no extra padding
/// or inner scroll view — the container hugs its content tightly.
///
/// When `reorderable` is true the rows expose SwiftUI 14 drag-and-
/// drop affordances (`.draggable` + `.dropDestination`) that call
/// `onMove(source, target)` to insert `source` immediately before
/// `target`.
struct MenuBarSegmentList: View {
    let title: String
    let items: [MenuBarSegment]
    let emptyHint: String?
    let reorderable: Bool
    let onToggle: (MenuBarSegment) -> Void
    var onMove: ((MenuBarSegment, MenuBarSegment) -> Void)?

    @State private var dropTarget: MenuBarSegment?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 4)

            container
        }
    }

    private var container: some View {
        Group {
            if items.isEmpty, let hint = emptyHint {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            } else {
                rowsStack
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color.gray.opacity(0.06), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.gray.opacity(0.18), lineWidth: 0.5)
        }
    }

    private var rowsStack: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, segment in
                row(for: segment)
                if index < items.count - 1 {
                    Divider().padding(.leading, 50)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for segment: MenuBarSegment) -> some View {
        let isTarget = dropTarget == segment
        let base = MenuBarSegmentRow(
            segment: segment,
            isSelected: reorderable,
            showsDragHandle: reorderable,
        ) {
            onToggle(segment)
        }
        .overlay(alignment: .top) {
            if isTarget {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }

        if reorderable {
            base
                .draggable(segment)
                .dropDestination(for: MenuBarSegment.self) { dropped, _ in
                    guard let source = dropped.first, source != segment else { return false }
                    onMove?(source, segment)
                    dropTarget = nil
                    return true
                } isTargeted: { targeted in
                    dropTarget = targeted ? segment : (dropTarget == segment ? nil : dropTarget)
                }
        } else {
            base
        }
    }
}
