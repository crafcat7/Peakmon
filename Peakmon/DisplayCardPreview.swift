//
//  DisplayCardPreview.swift
//  Peakmon
//
//  Top-of-page widget for Settings › Display. Mirrors the spirit of
//  `MenuBarLivePreview` on the General page: a compact, opinionated
//  visualisation of the user's current dashboard layout that doubles
//  as the *only* drag target for reordering cards. Per-card detail
//  configuration lives below in the dedicated sections, so the
//  drag-and-drop affordance is on lightweight thumbnail tiles
//  instead of the full configuration cards — a critical perf
//  decision after an earlier attempt to make the whole section
//  reorderable proved janky (every drag frame invalidated SwiftUI
//  state on six heavy `@AppStorage`-bound sub-sections).
//
//  The thumbnail layout is computed via `DashboardLayout.rows(from:)`
//  using the *currently visible* cards' widths, so what the user
//  sees here is bit-for-bit identical to the popover row grouping.
//  Hidden cards are still listed at half-size with a "hidden" pill
//  so the user can drag them into their preferred slot without
//  first enabling them.
//
//  Reorder mechanic uses SwiftUI 14's Transferable API
//  (`.draggable` + `.dropDestination`), matching the General page's
//  `MenuBarSegmentList`. Drop targets are highlighted with a 2pt
//  accent stroke instead of trying to interpolate a continuous
//  cursor offset — macOS provides crisp enter/exit events for that
//  pattern, and the implementation stays free of the perf cliffs
//  that come with chasing `DragGesture.location` at 60–120 Hz.
//

import SwiftUI

struct DisplayCardPreview: View {
    @Binding var order: [CardTintSlot]

    /// Visibility flags, addressed by slot. Hidden cards are still
    /// displayed in the preview at reduced opacity so the user can
    /// drag them around without first toggling them on.
    let visibility: [CardTintSlot: Bool]
    let widths: [CardTintSlot: CardWidth]
    let tints: [CardTintSlot: Color]

    @State private var dropTarget: CardTintSlot?

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                rowView(row)
            }
        }
        .padding(12)
        .background(
            // Subtle "popover-on-popover" background so the preview
            // visually reads as a live mock of the dashboard rather
            // than a normal Settings section.
            LinearGradient(
                colors: [
                    Color.gray.opacity(0.10),
                    Color.gray.opacity(0.05),
                ],
                startPoint: .top,
                endPoint: .bottom,
            ),
            in: .rect(cornerRadius: 12),
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.18), lineWidth: 0.5)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: order)
    }

    // MARK: - Layout

    /// Build the layout the same way `DashboardView` does so the
    /// preview faithfully reflects pairing of half-width cards.
    private var rows: [DashboardLayout.Row] {
        let cards: [DashboardLayout.VisibleCard] = order.map { slot in
            DashboardLayout.VisibleCard(
                slot: slot,
                width: widths[slot] ?? .full,
                // `AnyView` here is fine: the preview never actually
                // renders this view. It exists only so the
                // `VisibleCard` shape lines up with what
                // `DashboardLayout.rows(from:)` expects.
                view: AnyView(EmptyView()),
            )
        }
        return DashboardLayout.rows(from: cards)
    }

    @ViewBuilder
    private func rowView(_ row: DashboardLayout.Row) -> some View {
        switch row {
        case let .single(card):
            if card.width == .half {
                HStack(spacing: 10) {
                    thumbnail(for: card.slot)
                        .frame(maxWidth: .infinity)
                    Color.clear.frame(maxWidth: .infinity)
                }
            } else {
                thumbnail(for: card.slot)
                    .frame(maxWidth: .infinity)
            }
        case let .pair(lhs, rhs):
            HStack(spacing: 10) {
                thumbnail(for: lhs.slot)
                    .frame(maxWidth: .infinity)
                thumbnail(for: rhs.slot)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private func thumbnail(for slot: CardTintSlot) -> some View {
        let isVisible = visibility[slot] ?? true
        let tint = tints[slot] ?? .accentColor
        let isDropTarget = dropTarget == slot

        ThumbnailTile(
            slot: slot,
            tint: tint,
            isVisible: isVisible,
            isDropTarget: isDropTarget,
        )
        .draggable(slot) {
            // Custom drag preview. macOS hands the system this
            // snapshot to render under the cursor; the original
            // tile in the list is *not* dimmed automatically, so
            // intentionally do not toggle any source-side
            // "isBeingDragged" state — earlier prototypes did that
            // via `.onAppear`/`.onDisappear` on the preview and
            // ended up leaving the source tile permanently faded
            // because the preview view sometimes never reports a
            // disappearance after a drop into a non-target.
            ThumbnailTile(
                slot: slot,
                tint: tint,
                isVisible: isVisible,
                isDropTarget: false,
            )
            .frame(width: 180)
        }
        .dropDestination(for: CardTintSlot.self) { dropped, _ in
            dropTarget = nil
            guard let source = dropped.first, source != slot else { return false }
            move(source: source, near: slot)
            return true
        } isTargeted: { targeted in
            if targeted {
                dropTarget = slot
            } else if dropTarget == slot {
                dropTarget = nil
            }
        }
    }

    // MARK: - Mutations

    /// Move `source` so it lands next to `target` in `order`.
    ///
    /// The naive "insert before target" rule used by General ›
    /// Menu Bar produces a no-op whenever the user drags an item
    /// forward (a left tile dropped onto its right neighbour). In a
    /// vertical list that direction is rare enough to ignore, but
    /// the Display preview pairs half-width cards side-by-side so
    /// both directions are equally common. To keep horizontal drags
    /// working symmetrically, we insert *after* the target whenever
    /// the source originally sat before it, and *before* the target
    /// otherwise.
    private func move(source: CardTintSlot, near target: CardTintSlot) {
        guard let fromIndex = order.firstIndex(of: source),
              let toIndex = order.firstIndex(of: target),
              fromIndex != toIndex else { return }
        var next = order
        next.remove(at: fromIndex)
        // Recompute target index after removal so the insertion
        // offset matches the now-shorter array.
        guard let adjustedTo = next.firstIndex(of: target) else {
            next.append(source)
            order = next
            return
        }
        let insertIndex = fromIndex < toIndex
            ? adjustedTo + 1  // dragging forward → drop after target
            : adjustedTo      // dragging backward → drop before target
        next.insert(source, at: min(insertIndex, next.count))
        order = next
    }
}

// MARK: - Thumbnail tile

/// Lightweight visual cell for a single card slot. Pure value-based
/// inputs only — no `@AppStorage`, no `MetricsStore` — so SwiftUI
/// can diff thousands of these per second without triggering the
/// kind of body-recompute storms that doomed the earlier
/// reorderable-row prototype.
private struct ThumbnailTile: View {
    let slot: CardTintSlot
    let tint: Color
    let isVisible: Bool
    let isDropTarget: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(isVisible ? 0.18 : 0.08))
                    .frame(width: 30, height: 30)
                Image(systemName: slot.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isVisible ? tint : Color.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(slot.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                if !isVisible {
                    Text("Hidden")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Color.secondary.opacity(0.18),
                            in: .capsule,
                        )
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor)
                .opacity(isVisible ? 1.0 : 0.55),
            in: .rect(cornerRadius: 8),
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isDropTarget ? Color.accentColor : Color.gray.opacity(0.16),
                    lineWidth: isDropTarget ? 1.5 : 0.5,
                )
        }
        .overlay(alignment: .leading) {
            // 2pt accent bar mirrors General › Menu Bar's insertion
            // indicator. Sits on the leading edge because Display
            // cards stack vertically and drag moves rows up/down;
            // the bar reads as "source will land here, pushing this
            // card down".
            if isDropTarget {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .clipShape(.rect(cornerRadius: 1.5))
                    .padding(.vertical, 4)
            }
        }
        .opacity(isVisible ? 1 : 0.85)
        .animation(.easeInOut(duration: 0.15), value: isDropTarget)
        .contentShape(.rect)
    }
}
