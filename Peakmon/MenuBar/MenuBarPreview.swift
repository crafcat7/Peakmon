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

    @Environment(\.cardSettings) private var cardSettings
    @Environment(HistoryIssuesStore.self) private var historyIssuesStore

    var body: some View {
        // Wrap the pill in a horizontal ScrollView so the preview's
        // intrinsic width never feeds back into NavigationSplitView's
        // column-sizing pass. Without this, adding every segment grows
        // the pill past the window's ideal width and SwiftUI compensates
        // by shrinking the sidebar column to near-zero.
        //
        // GeometryReader supplies the viewport width as a `minWidth`
        // on the inner HStack so:
        //  - short selections: HStack stretches to viewport width,
        //    the two Spacers centre the pill;
        //  - long selections: HStack falls back to the pill's own
        //    intrinsic width, Spacers collapse, and ScrollView pans.
        GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    content
                        .padding(.horizontal, 12)
                        .frame(height: 30)
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
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .frame(minWidth: proxy.size.width)
            }
        }
        .frame(height: 42)
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
            HStack(spacing: 6) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.white.opacity(0.35))
                            .frame(width: 0.5, height: 16)
                    }
                    MenuBarSegmentBlock(
                        segment: segment,
                        store: store,
                        tints: [
                            .cpu: cardSettings.tint(.cpu),
                            .memory: cardSettings.tint(.memory),
                            .disk: cardSettings.tint(.disk),
                            .network: cardSettings.tint(.network),
                            .gpu: cardSettings.tint(.gpu),
                            .power: cardSettings.tint(.power),
                        ],
                        historyIssuesStore: historyIssuesStore,
                    )
                }
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white)
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

                    Text(LocalizedStringKey(segment.title))
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
            Text(LocalizedStringKey(title))
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
                Text(LocalizedStringKey(hint))
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
