//
//  CardWidth.swift
//  Peakmon
//
//  Per-card width preference. Each dashboard slot can render at full
//  popover width (the historical default) or as a half-width tile;
//  consecutive half-width cards in the user's visible order get
//  packed two-per-row by `DashboardLayout`.
//
//  Stored as `@AppStorage("cardWidth.<slot>")` so the preference
//  travels with the user across launches and survives card-visibility
//  toggles. Reading uses raw `String` rather than `RawRepresentable`
//  bridging because `@AppStorage` does not support custom enums
//  directly without a manual codable layer, and the explicit string
//  keeps the user defaults file legible.
//

import SwiftUI

enum CardWidth: String, CaseIterable, Identifiable {
    /// Card spans the full popover row. Required for cards whose
    /// content does not compress well — sparklines that need wide
    /// horizontal range, multi-stat headers, etc.
    case full

    /// Card occupies half a popover row. Two adjacent half cards in
    /// the user's visible order render side-by-side in an `HStack`.
    /// A trailing un-paired half is laid out alone at half width.
    case half

    var id: String { rawValue }

    var label: String {
        switch self {
        case .full: "Full"
        case .half: "Half"
        }
    }

    static func storageKey(for slot: CardTintSlot) -> String {
        "cardWidth.\(slot.rawValue)"
    }

    /// Factory default. CPU and Memory are full-width because their
    /// sparklines + multi-stat headers crowd badly at half width;
    /// battery / disk / network / processes default to full too so
    /// the new feature is purely opt-in and does not visually disturb
    /// users on first launch after upgrading.
    static func defaultValue(for _: CardTintSlot) -> CardWidth { .full }
}

/// Property wrapper mirroring `CardTintStorage` for the width
/// preference. Centralises the storage-key convention so the rest of
/// the app does not have to know how the preference is encoded.
@MainActor
@propertyWrapper
struct CardWidthStorage: DynamicProperty {
    let slot: CardTintSlot
    @AppStorage private var raw: String

    init(_ slot: CardTintSlot) {
        self.slot = slot
        _raw = AppStorage(
            wrappedValue: CardWidth.defaultValue(for: slot).rawValue,
            CardWidth.storageKey(for: slot),
        )
    }

    var wrappedValue: CardWidth {
        get { CardWidth(rawValue: raw) ?? .full }
        nonmutating set { raw = newValue.rawValue }
    }

    var projectedValue: Binding<CardWidth> {
        Binding(
            get: { CardWidth(rawValue: raw) ?? .full },
            set: { raw = $0.rawValue },
        )
    }
}
