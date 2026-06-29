//
//  CardSettings.swift
//  Peakmon
//
//  Centralised access to every card's persisted preferences
//  (visibility, width, tint) so call sites no longer hand-roll one
//  `@CardVisibilityStorage` / `@CardWidthStorage` / `@CardTintStorage`
//  per slot per view.
//
//  Why a struct of closures instead of `@Observable`?
//  --------------------------------------------------
//  The underlying storage is `@AppStorage`, which is a SwiftUI
//  property wrapper that observes `UserDefaults` only inside a `View`.
//  Wrapping it inside an `@Observable` class would require manual
//  KVO/Notification plumbing and reintroduces drift risk. Instead we
//  keep the 24 property wrappers in a single container view —
//  `CardSettingsScope` — which exposes them as closures through the
//  environment. SwiftUI invalidates that view and its children when
//  any `@AppStorage`-backed key changes, so dependents re-evaluate
//  automatically without any observation glue.
//
//  Read access goes through `settings.visibility(slot) / width(slot) /
//  tint(slot)`; write access through `settings.visibilityBinding(slot)`
//  etc. so SwiftUI controls (`Toggle`, `Picker`, `ColorPicker`) keep
//  working.
//

import SwiftUI

@MainActor
struct CardSettings {
    let visibility: (CardTintSlot) -> Bool
    let width: (CardTintSlot) -> CardWidth
    let tint: (CardTintSlot) -> Color
    let visibilityBinding: (CardTintSlot) -> Binding<Bool>
    let widthBinding: (CardTintSlot) -> Binding<CardWidth>
    let tintBinding: (CardTintSlot) -> Binding<Color>
    let resetTint: (CardTintSlot) -> Void
    let order: () -> [CardTintSlot]
    let orderBinding: () -> Binding<[CardTintSlot]>

    /// Snapshot of every slot's current values, useful for views that
    /// want dictionaries (e.g. `DisplayCardPreview`).
    func visibilityMap() -> [CardTintSlot: Bool] {
        Dictionary(uniqueKeysWithValues: CardTintSlot.allCases.map { ($0, visibility($0)) })
    }

    func widthMap() -> [CardTintSlot: CardWidth] {
        Dictionary(uniqueKeysWithValues: CardTintSlot.allCases.map { ($0, width($0)) })
    }

    func tintMap() -> [CardTintSlot: Color] {
        Dictionary(uniqueKeysWithValues: CardTintSlot.allCases.map { ($0, tint($0)) })
    }
}

private struct CardSettingsKey: @preconcurrency EnvironmentKey {
    @MainActor
    static let defaultValue: CardSettings = .placeholder
}

extension EnvironmentValues {
    var cardSettings: CardSettings {
        get { self[CardSettingsKey.self] }
        set { self[CardSettingsKey.self] = newValue }
    }
}

extension CardSettings {
    /// Inert fallback used when no `CardSettingsScope` is in the
    /// ancestor chain — returns factory defaults and discards writes.
    /// Should never be hit in production; exists only to satisfy the
    /// `EnvironmentKey.defaultValue` requirement.
    @MainActor
    static let placeholder = CardSettings(
        visibility: { $0.visibilityDefault },
        width: { CardWidth.defaultValue(for: $0) },
        tint: { $0.defaultColor },
        visibilityBinding: { _ in .constant(true) },
        widthBinding: { slot in .constant(CardWidth.defaultValue(for: slot)) },
        tintBinding: { slot in .constant(slot.defaultColor) },
        resetTint: { _ in },
        order: { CardOrderStorage.defaultOrder },
        orderBinding: { .constant(CardOrderStorage.defaultOrder) },
    )
}

// MARK: - Scope container

/// Holds the 24 per-slot `@CardXxxStorage` wrappers + the card order
/// in a single view and injects a `CardSettings` into its subtree via
/// the environment.
///
/// Place this once near the app root, wrapping every consumer
/// (`DashboardView`, `SettingsView`, `MenuBarLabel`). When any
/// underlying `@AppStorage` key changes, SwiftUI re-evaluates this
/// view, rebuilds the closure tuple, and propagates the new values to
/// every descendant that reads `\.cardSettings`.
struct CardSettingsScope<Content: View>: View {
    @CardVisibilityStorage(.cpu) private var showCPU
    @CardVisibilityStorage(.memory) private var showMemory
    @CardVisibilityStorage(.battery) private var showBattery
    @CardVisibilityStorage(.disk) private var showDisk
    @CardVisibilityStorage(.network) private var showNetwork
    @CardVisibilityStorage(.processes) private var showProcesses
    @CardVisibilityStorage(.gpu) private var showGPU
    @CardVisibilityStorage(.power) private var showPower

    @CardWidthStorage(.cpu) private var cpuWidth
    @CardWidthStorage(.memory) private var memoryWidth
    @CardWidthStorage(.battery) private var batteryWidth
    @CardWidthStorage(.disk) private var diskWidth
    @CardWidthStorage(.network) private var networkWidth
    @CardWidthStorage(.processes) private var processesWidth
    @CardWidthStorage(.gpu) private var gpuWidth
    @CardWidthStorage(.power) private var powerWidth

    @CardTintStorage(.cpu) private var cpuTint
    @CardTintStorage(.memory) private var memoryTint
    @CardTintStorage(.battery) private var batteryTint
    @CardTintStorage(.disk) private var diskTint
    @CardTintStorage(.network) private var networkTint
    @CardTintStorage(.processes) private var processesTint
    @CardTintStorage(.gpu) private var gpuTint
    @CardTintStorage(.power) private var powerTint

    @CardOrderStorage private var cardOrder: [CardTintSlot]

    @ViewBuilder let content: () -> Content

    init(
        @ViewBuilder content: @escaping () -> Content,
    ) {
        self.content = content
    }

    var body: some View {
        content().environment(\.cardSettings, makeSettings())
    }

    private func makeSettings() -> CardSettings {
        CardSettings(
            visibility: { slot in
                return switch slot {
                case .cpu: showCPU
                case .memory: showMemory
                case .battery: showBattery
                case .disk: showDisk
                case .network: showNetwork
                case .processes: showProcesses
                case .gpu: showGPU
                case .power: showPower
                }
            },
            width: { slot in
                switch slot {
                case .cpu: cpuWidth
                case .memory: memoryWidth
                case .battery: batteryWidth
                case .disk: diskWidth
                case .network: networkWidth
                case .processes: processesWidth
                case .gpu: gpuWidth
                case .power: powerWidth
                }
            },
            tint: { slot in
                switch slot {
                case .cpu: cpuTint
                case .memory: memoryTint
                case .battery: batteryTint
                case .disk: diskTint
                case .network: networkTint
                case .processes: processesTint
                case .gpu: gpuTint
                case .power: powerTint
                }
            },
            visibilityBinding: { slot in
                return switch slot {
                case .cpu: $showCPU
                case .memory: $showMemory
                case .battery: $showBattery
                case .disk: $showDisk
                case .network: $showNetwork
                case .processes: $showProcesses
                case .gpu: $showGPU
                case .power: $showPower
                }
            },
            widthBinding: { slot in
                switch slot {
                case .cpu: $cpuWidth
                case .memory: $memoryWidth
                case .battery: $batteryWidth
                case .disk: $diskWidth
                case .network: $networkWidth
                case .processes: $processesWidth
                case .gpu: $gpuWidth
                case .power: $powerWidth
                }
            },
            tintBinding: { slot in
                switch slot {
                case .cpu: $cpuTint
                case .memory: $memoryTint
                case .battery: $batteryTint
                case .disk: $diskTint
                case .network: $networkTint
                case .processes: $processesTint
                case .gpu: $gpuTint
                case .power: $powerTint
                }
            },
            resetTint: { slot in
                switch slot {
                case .cpu: _cpuTint.reset()
                case .memory: _memoryTint.reset()
                case .battery: _batteryTint.reset()
                case .disk: _diskTint.reset()
                case .network: _networkTint.reset()
                case .processes: _processesTint.reset()
                case .gpu: _gpuTint.reset()
                case .power: _powerTint.reset()
                }
            },
            order: { cardOrder },
            orderBinding: { $cardOrder },
        )
    }
}
