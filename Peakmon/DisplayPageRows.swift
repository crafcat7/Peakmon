//
//  DisplayPageRows.swift
//  Peakmon
//
//  Row views used by the Display settings page. Each metric block
//  composes these rows inside a per-metric `SettingsSection`:
//
//    - `MetricShowRow`     — "Show in dashboard" master toggle.
//    - `CardTintRow`       — accent colour swatch + reset.
//    - `ChartSeriesRow`    — sparkline series checkboxes.
//    - `ChartSeriesToggle` — single labelled checkbox primitive.
//
//  Extracted from `SettingsView.swift` so that file stays under the
//  SwiftLint `file_length` ceiling.
//

import PeakmonUI
import SwiftUI

struct MetricShowRow: View {
    let title: String
    let systemImage: String
    let slot: CardTintSlot
    @Binding var isOn: Bool
    @CardTintStorage private var tint: Color

    init(
        title: String,
        systemImage: String,
        slot: CardTintSlot,
        isOn: Binding<Bool>,
    ) {
        self.title = title
        self.systemImage = systemImage
        self.slot = slot
        _isOn = isOn
        _tint = CardTintStorage(slot)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 18)
            Text("Show in dashboard")
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
    }
}

struct ChartSeriesRow: View {
    let series: [ChartSeries]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "chart.xyaxis.line")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("Chart series")
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 4)

            VStack(spacing: 0) {
                ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.vertical, 2) }
                    ChartSeriesLine(series: item)
                }
            }
            .padding(.leading, 28)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
    }
}

/// One line inside `ChartSeriesRow`: a checkbox-style toggle for
/// enabled state, plus a `ColorPicker` to override the series tint
/// and an inline Reset button when the user has diverged from the
/// default.
struct ChartSeriesLine: View {
    let series: ChartSeries
    @AppStorage private var enabled: Bool
    @ChartSeriesTintStorage private var tint: Color

    init(series: ChartSeries) {
        self.series = series
        _enabled = AppStorage(wrappedValue: series.defaultEnabled, series.storageKey)
        _tint = ChartSeriesTintStorage(series)
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $enabled) {
                Text(series.title)
                    .font(.callout)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            Spacer()
            if tint.hexString.uppercased() != series.defaultHex.uppercased() {
                Button("Reset") { _tint.reset() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ColorPicker("", selection: $tint, supportsOpacity: false)
                .labelsHidden()
        }
        .contextMenu {
            Button("Reset to default") { _tint.reset() }
        }
    }
}

struct CardTintRow: View {
    let slot: CardTintSlot
    let hideIcon: Bool
    @CardTintStorage private var tint: Color

    init(slot: CardTintSlot, hideIcon: Bool = false) {
        self.slot = slot
        self.hideIcon = hideIcon
        _tint = CardTintStorage(slot)
    }

    var body: some View {
        HStack(spacing: 10) {
            if hideIcon {
                Image(systemName: "paintpalette")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            } else {
                Image(systemName: slot.systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 18)
            }
            Text(hideIcon ? "Card tint" : slot.title)
            Spacer()
            if tint.hexString.uppercased() != slot.defaultHex.uppercased() {
                Button("Reset") { _tint.reset() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ColorPicker("", selection: $tint, supportsOpacity: false)
                .labelsHidden()
        }
        .contextMenu {
            Button("Reset to default") { _tint.reset() }
        }
    }
}

struct ChartSeriesToggle: View {
    let series: ChartSeries
    @AppStorage private var enabled: Bool
    @ChartSeriesTintStorage private var tint: Color

    init(series: ChartSeries) {
        self.series = series
        _enabled = AppStorage(wrappedValue: series.defaultEnabled, series.storageKey)
        _tint = ChartSeriesTintStorage(series)
    }

    var body: some View {
        Toggle(isOn: $enabled) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                Text(series.title)
                    .font(.callout)
            }
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
    }
}

/// Segmented Full / Half picker for a card's `CardWidthStorage`.
/// Placed inside each metric section so the user sees width and tint
/// preferences live next to each other for the same card; matches
/// the visual rhythm of `CardTintRow`.
struct CardWidthRow: View {
    let slot: CardTintSlot
    @CardWidthStorage private var width: CardWidth

    init(slot: CardTintSlot) {
        self.slot = slot
        _width = CardWidthStorage(slot)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.split.2x1")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text("Width")
            Spacer()
            Picker("", selection: $width) {
                ForEach(CardWidth.allCases) { value in
                    Text(value.label).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }
}
