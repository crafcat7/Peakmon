//
//  ChartSeries.swift
//  Peakmon
//
//  User-controlled toggles for which `MetricKind` series appear
//  in each dashboard sparkline. CPU/Disk/Network cards each expose
//  two complementary series that the user can independently show
//  or hide:
//
//    - CPU:     `cpuUser`     +  `cpuSystem`
//    - Disk:    `diskReadRate` + `diskWriteRate`
//    - Network: `netInRate`    + `netOutRate`
//
//  Selection state lives in `@AppStorage` under string keys so it
//  persists across launches without bringing in GRDB just yet.
//
//  Defaults: both series enabled for every card.
//

import Foundation
import PeakmonCore
import PeakmonUI
import SwiftUI

/// Identifies a single togglable series on a dashboard sparkline.
enum ChartSeries: String, CaseIterable, Identifiable, Hashable {
    case cpuTotal
    case cpuUser
    case cpuSystem
    case diskRead
    case diskWrite
    case netIn
    case netOut
    case gpuDevice
    case powerCPU
    case powerGPU
    case powerDRAM

    var id: String { rawValue }

    /// The underlying metric this series renders.
    var metric: MetricKind {
        switch self {
        case .cpuTotal: .cpuTotal
        case .cpuUser: .cpuUser
        case .cpuSystem: .cpuSystem
        case .diskRead: .diskReadRate
        case .diskWrite: .diskWriteRate
        case .netIn: .netInRate
        case .netOut: .netOutRate
        case .gpuDevice: .gpuUtilization
        case .powerCPU: .powerCPU
        case .powerGPU: .powerGPU
        case .powerDRAM: .powerDRAM
        }
    }

    /// Display label shown in the settings checkbox row.
    var title: String {
        switch self {
        case .cpuTotal: "Total"
        case .cpuUser: "User"
        case .cpuSystem: "System"
        case .diskRead: "Read"
        case .diskWrite: "Write"
        case .netIn: "Download"
        case .netOut: "Upload"
        case .gpuDevice: "Device"
        case .powerCPU: "CPU"
        case .powerGPU: "GPU"
        case .powerDRAM: "DRAM"
        }
    }

    /// Default tint baked into each series. Used both as the
    /// initial value on first launch and as the target of a Reset.
    var defaultTint: Color {
        switch self {
        case .cpuTotal: .purple
        case .cpuUser: .blue
        case .cpuSystem: .orange
        case .diskRead: .teal
        case .diskWrite: .pink
        case .netIn: .green
        case .netOut: .indigo
        case .gpuDevice: .indigo
        case .powerCPU: .blue
        case .powerGPU: .indigo
        case .powerDRAM: .teal
        }
    }

    /// Hex string for `defaultTint`, used by reset detection in the
    /// settings UI. Derived from `defaultTint` so the two cannot
    /// drift out of sync.
    var defaultHex: String { defaultTint.hexString }

    /// `@AppStorage` key for the on/off boolean.
    var storageKey: String { "chart.series.\(rawValue)" }

    /// `@AppStorage` key for the user-overridable tint hex value.
    var tintKey: String { "chart.series.\(rawValue).color" }

    /// Default enabled state on first launch. CPU defaults to
    /// User+System on; Total off to avoid visual redundancy with the
    /// big percentage in the card header. GPU only enables the Device
    /// series by default — on Apple Silicon the IOAccelerator driver
    /// reports the same value for `Renderer Utilization %` and
    /// `Tiler Utilization %` as `Device Utilization %` outside of
    /// specific workloads, so showing all three lines just produces
    /// a single overlapping trace. Users with discrete GPUs (Intel
    /// Macs + eGPU) can opt back in from Settings › Display.
    var defaultEnabled: Bool {
        switch self {
        case .cpuTotal: false
        default: true
        }
    }
}

/// Persists a per-series tint colour as a hex string in
/// `@AppStorage`. Mirrors the pattern used by `CardTintStorage`.
@propertyWrapper
struct ChartSeriesTintStorage: DynamicProperty {
    @AppStorage private var hex: String
    let series: ChartSeries

    init(_ series: ChartSeries) {
        self.series = series
        _hex = AppStorage(wrappedValue: series.defaultHex, series.tintKey)
    }

    var wrappedValue: Color {
        get { Color(hex: hex) ?? series.defaultTint }
        nonmutating set { hex = newValue.hexString }
    }

    var projectedValue: Binding<Color> {
        Binding(
            get: { wrappedValue },
            set: { wrappedValue = $0 },
        )
    }

    func reset() {
        hex = series.defaultHex
    }
}

extension ChartSeries {
    /// Reads the user's current tint colour from `UserDefaults`
    /// directly. Used by view code that needs a colour value
    /// outside of a SwiftUI property-wrapper context (e.g. the
    /// sparkline series builder).
    var storedTint: Color {
        let stored = UserDefaults.standard.string(forKey: tintKey) ?? defaultHex
        return Color(hex: stored) ?? defaultTint
    }
}

/// Lightweight property wrapper that mirrors a `ChartSeries`'s
/// enabled state into `@AppStorage`. Defaults to `true` so first
/// launch shows both series everywhere.
@propertyWrapper
struct ChartSeriesEnabled: DynamicProperty {
    @AppStorage private var storage: Bool
    let series: ChartSeries

    init(_ series: ChartSeries) {
        self.series = series
        _storage = AppStorage(wrappedValue: series.defaultEnabled, series.storageKey)
    }

    var wrappedValue: Bool {
        get { storage }
        nonmutating set { storage = newValue }
    }

    var projectedValue: Binding<Bool> { $storage }
}
