//
//  CardOrder.swift
//  Peakmon
//
//  Persists the Popover card order. Half-width metric cards and
//  full-width summary cards remain separate groups so every saved
//  arrangement still fits the fixed, non-scrolling Popover.
//

import SwiftUI

@MainActor
@propertyWrapper
struct CardOrderStorage: DynamicProperty {
    @AppStorage("cardOrder") private var raw = Self.encode(Self.defaultOrder)

    static let defaultOrder = CardTintSlot.displayOrder

    var wrappedValue: [CardTintSlot] {
        get { Self.normalized(Self.decode(raw)) }
        nonmutating set { raw = Self.encode(Self.normalized(newValue)) }
    }

    var projectedValue: Binding<[CardTintSlot]> {
        Binding(
            get: { Self.normalized(Self.decode(raw)) },
            set: { raw = Self.encode(Self.normalized($0)) },
        )
    }

    func reset() {
        raw = Self.encode(Self.defaultOrder)
    }

    /// Remove duplicates, append newly introduced slots, then keep
    /// half-width metrics ahead of the two full-width summary cards.
    /// The stable filters preserve the user's order inside each group.
    static func normalized(_ slots: [CardTintSlot]) -> [CardTintSlot] {
        var seen = Set<CardTintSlot>()
        var complete = slots.filter { seen.insert($0).inserted }
        complete.append(contentsOf: defaultOrder.filter { seen.insert($0).inserted })

        let metrics = complete.filter { CardWidth.defaultValue(for: $0) == .half }
        let summaries = complete.filter { CardWidth.defaultValue(for: $0) == .full }
        return metrics + summaries
    }

    static func encode(_ slots: [CardTintSlot]) -> String {
        slots.map(\.rawValue).joined(separator: ",")
    }

    static func decode(_ raw: String) -> [CardTintSlot] {
        raw.split(separator: ",").compactMap {
            CardTintSlot(rawValue: String($0))
        }
    }
}
