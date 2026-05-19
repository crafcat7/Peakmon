//
//  CardOrder.swift
//  Peakmon
//
//  Persists the user's chosen top-to-bottom card order for the
//  dashboard popover and the Settings › Display page.
//
//  Storage format is a comma-separated list of `CardTintSlot`
//  rawValues under the `cardOrder` `@AppStorage` key — kept as a
//  string (instead of e.g. `Data` of a Codable array) so the value
//  is human-readable when inspecting `~/Library/Preferences/...`
//  plist files during development, and so missing slots can be
//  spotted at a glance.
//
//  Slots are auto-appended at the end of the stored order whenever a
//  new canonical slot is introduced in the codebase (see
//  `normalized(_:)`). This means future card additions don't need a
//  migration step — they simply show up at the bottom for existing
//  users until they reorder.
//

import SwiftUI

/// Reads/writes the persisted card order, falling back to the
/// canonical default (CPU first, Processes last). Updates flow back
/// to `@AppStorage` so every observer (Display page + DashboardView)
/// stays in sync.
@MainActor
@propertyWrapper
struct CardOrderStorage: DynamicProperty {
    @AppStorage("cardOrder") private var raw: String = Self.encode(Self.defaultOrder)

    static let defaultOrder: [CardTintSlot] = [
        .cpu, .memory, .battery, .disk, .network, .processes,
    ]

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

    /// Restore the canonical factory order.
    func reset() {
        raw = Self.encode(Self.defaultOrder)
    }

    // MARK: - Helpers

    /// Drops unknown rawValues (forward-compat) and appends any
    /// canonical slot that the stored list is missing (backward-
    /// compat after a new card is added to the app).
    static func normalized(_ slots: [CardTintSlot]) -> [CardTintSlot] {
        var seen = Set<CardTintSlot>()
        var result: [CardTintSlot] = []
        for slot in slots where !seen.contains(slot) {
            seen.insert(slot)
            result.append(slot)
        }
        for slot in defaultOrder where !seen.contains(slot) {
            result.append(slot)
        }
        return result
    }

    static func encode(_ slots: [CardTintSlot]) -> String {
        slots.map(\.rawValue).joined(separator: ",")
    }

    static func decode(_ raw: String) -> [CardTintSlot] {
        raw.split(separator: ",", omittingEmptySubsequences: true).compactMap {
            CardTintSlot(rawValue: String($0))
        }
    }
}
