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

    /// Factory default. The dashboard ships with a paired-row layout:
    /// CPU/GPU, Memory/Battery, Disk/Network occupy three half-width
    /// rows; Power and Processes each take their own full-width row
    /// because their content (the SMC system-power headline + DISP/
    /// DRAM/FAN sub-rails for Power; the process table for Processes)
    /// does not compress usefully. New users see this packed layout
    /// on first launch; users with an existing `cardWidth.<slot>`
    /// preference are unaffected because `@AppStorage` only consults
    /// the default when the key is absent.
    static func defaultValue(for slot: CardTintSlot) -> CardWidth {
        switch slot {
        case .power, .processes: .full
        case .cpu, .memory, .battery, .disk, .network, .gpu: .half
        }
    }
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
