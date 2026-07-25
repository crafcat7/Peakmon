//
//  DashboardLayout.swift
//  Peakmon
//
//  Lays out visible dashboard cards using fixed product width roles
//  (`CardWidth`). Two consecutive half-width cards in canonical order
//  pack into one HStack row;
//  full-width cards always occupy a row alone; an unpaired trailing
//  half-width card becomes a single row that the renderer promotes
//  to full width, avoiding an empty half-row in the popover.
//

import SwiftUI

/// Pre-computed row buckets ready for SwiftUI to materialise.
///
/// We model this as an explicit array of rows rather than a stream
/// of `if showX { xCard }` statements because SwiftUI's `@ViewBuilder`
/// cannot conditionally pair sibling views inside an HStack without
/// us first deciding the grouping. The grouping is a function of
/// (visibility, width) for the visible slots in the persisted user order;
/// `DashboardLayout.rows` produces that grouping once per body
/// evaluation in a single pass.
enum DashboardLayout {
    /// One row's worth of cards. `.single` covers both `full`-width
    /// cards and a lone trailing `half` card; `.pair` is exactly two
    /// half cards rendered side-by-side.
    enum Row {
        case single(VisibleCard)
        case pair(VisibleCard, VisibleCard)

        /// Stable identity derived from the contained slot(s).
        /// Used as `ForEach` ID so SwiftUI correctly animates
        /// reordering instead of reusing views by array offset.
        var rowID: String {
            switch self {
            case let .single(card): card.slot.rawValue
            case let .pair(a, b): a.slot.rawValue + "+" + b.slot.rawValue
            }
        }
    }

    /// Pairing of a slot identifier with the user's chosen width.
    /// The view is dispatched by slot in `DashboardView.rowView`
    /// so SwiftUI preserves structural identity across re-evaluations.
    struct VisibleCard: Identifiable {
        let slot: CardTintSlot
        let width: CardWidth

        var id: String { slot.rawValue }
    }

    /// Greedy left-to-right packer. Walks the visible-card list once;
    /// when the next card is `.half` and the immediately following
    /// card is also `.half`, emits a `.pair`. A lone `.half` at the
    /// end (or with a `.full` neighbour) becomes a `.single` so the
    /// user always sees their card even if the pairing partner is
    /// hidden.
    static func rows(from cards: [VisibleCard]) -> [Row] {
        var result: [Row] = []
        var index = cards.startIndex
        while index < cards.endIndex {
            let current = cards[index]
            if current.width == .half,
               index + 1 < cards.endIndex,
               cards[index + 1].width == .half {
                result.append(.pair(current, cards[index + 1]))
                index += 2
            } else {
                result.append(.single(current))
                index += 1
            }
        }
        return result
    }
}
