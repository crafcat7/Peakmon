//
//  CardTint.swift
//  Peakmon
//
//  Per-card tint persistence. Each dashboard card has a tint colour
//  stored as a `#RRGGBB` string in `@AppStorage`, with a sensible
//  default that matches the app's original palette.
//

import CoreTransferable
import PeakmonUI
import SwiftUI
import UniformTypeIdentifiers

enum CardTintSlot: String, CaseIterable, Identifiable, Codable, Transferable {
    case cpu
    case memory
    case battery
    case disk
    case network
    case processes

    var id: String { rawValue }

    /// `CardTintSlot` is moved between views by the Display page's
    /// reorder UI; declare the transfer representation here so any
    /// view can mark itself `.draggable(slot)` /
    /// `.dropDestination(for: CardTintSlot.self)`.
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .plainText)
    }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .battery: "Battery"
        case .disk: "Disk"
        case .network: "Network"
        case .processes: "Processes"
        }
    }

    var systemImage: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .battery: "battery.100percent"
        case .disk: "internaldrive"
        case .network: "network"
        case .processes: "list.bullet.rectangle"
        }
    }

    var storageKey: String { "cardTint.\(rawValue)" }

    /// Hex string for the factory default tint.
    var defaultHex: String {
        switch self {
        case .cpu: "#007AFF" // .blue
        case .memory: "#AF52DE" // .purple
        case .battery: "#34C759" // .green
        case .disk: "#32ADE6" // .cyan
        case .network: "#FF2D55" // .pink
        case .processes: "#FF9500" // .orange
        }
    }

    var defaultColor: Color {
        Color(hex: defaultHex) ?? .accentColor
    }
}

/// Reads the persisted tint for a slot, falling back to the factory
/// default. Updates flow back to `@AppStorage` and so update every
/// view that observes the same key.
@MainActor
@propertyWrapper
struct CardTintStorage: DynamicProperty {
    let slot: CardTintSlot
    @AppStorage private var hex: String

    init(_ slot: CardTintSlot) {
        self.slot = slot
        _hex = AppStorage(wrappedValue: slot.defaultHex, slot.storageKey)
    }

    var wrappedValue: Color {
        get { Color(hex: hex) ?? slot.defaultColor }
        nonmutating set { hex = newValue.hexString }
    }

    var projectedValue: Binding<Color> {
        Binding(
            get: { Color(hex: hex) ?? slot.defaultColor },
            set: { hex = $0.hexString },
        )
    }

    /// Reset the persisted tint to the factory default.
    func reset() {
        hex = slot.defaultHex
    }
}
