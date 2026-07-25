//
//  DisplayCardPreview.swift
//  Peakmon
//
//  Lightweight Popover layout preview and drag target. It deliberately
//  avoids live metric views so dragging does not invalidate collectors,
//  charts, or AppStorage-heavy configuration sections on every frame.
//

import SwiftUI

struct DisplayCardPreview: View {
    @Binding var order: [CardTintSlot]
    let visibility: [CardTintSlot: Bool]
    let tints: [CardTintSlot: Color]

    @State private var dropTarget: CardTintSlot?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 10) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    rowView(row)
                }
            }
            .padding(12)
            .background(previewBackground, in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.gray.opacity(0.18), lineWidth: 0.5)
            }

            Text("Drag to reorder. Metric cards stay paired; Battery and Processes remain full width.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: order)
    }

    private var previewBackground: LinearGradient {
        LinearGradient(
            colors: [Color.gray.opacity(0.10), Color.gray.opacity(0.05)],
            startPoint: .top,
            endPoint: .bottom,
        )
    }

    private var rows: [DashboardLayout.Row] {
        DashboardLayout.rows(from: order.map {
            DashboardLayout.VisibleCard(
                slot: $0,
                width: CardWidth.defaultValue(for: $0),
            )
        })
    }

    @ViewBuilder
    private func rowView(_ row: DashboardLayout.Row) -> some View {
        switch row {
        case let .single(card):
            thumbnail(for: card.slot)
                .frame(maxWidth: .infinity)
        case let .pair(lhs, rhs):
            HStack(spacing: 10) {
                thumbnail(for: lhs.slot)
                    .frame(maxWidth: .infinity)
                thumbnail(for: rhs.slot)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func thumbnail(for slot: CardTintSlot) -> some View {
        let isVisible = visibility[slot] ?? true
        let tint = tints[slot] ?? .accentColor

        return DisplayCardThumbnail(
            slot: slot,
            tint: tint,
            isVisible: isVisible,
            isDropTarget: dropTarget == slot,
        )
        .draggable(slot) {
            DisplayCardThumbnail(
                slot: slot,
                tint: tint,
                isVisible: isVisible,
                isDropTarget: false,
            )
            .frame(width: 180)
        }
        .dropDestination(for: CardTintSlot.self) { dropped, _ in
            dropTarget = nil
            guard let source = dropped.first,
                  source != slot,
                  CardWidth.defaultValue(for: source) == CardWidth.defaultValue(for: slot) else {
                return false
            }
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

    /// Insert after the target when dragging forward and before it
    /// when dragging backward, making horizontal pair swaps symmetric.
    private func move(source: CardTintSlot, near target: CardTintSlot) {
        guard let fromIndex = order.firstIndex(of: source),
              let toIndex = order.firstIndex(of: target),
              fromIndex != toIndex else { return }

        var next = order
        next.remove(at: fromIndex)
        guard let adjustedTarget = next.firstIndex(of: target) else { return }
        let insertion = fromIndex < toIndex ? adjustedTarget + 1 : adjustedTarget
        next.insert(source, at: min(insertion, next.endIndex))
        order = next
    }
}

private struct DisplayCardThumbnail: View {
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
                    .lineLimit(1)
                if !isVisible {
                    Text("Hidden")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(isVisible ? 1 : 0.55),
            in: .rect(cornerRadius: 8),
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isDropTarget ? Color.accentColor : Color.gray.opacity(0.16),
                    lineWidth: isDropTarget ? 1.5 : 0.5,
                )
        }
        .opacity(isVisible ? 1 : 0.85)
        .contentShape(.rect)
    }
}
