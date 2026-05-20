//
//  MenuBarSegmentBlock.swift
//  Peakmon
//
//  Template-driven rendering for a single `MenuBarSegment`. Used by
//  both the rasterised system menu-bar label (`MenuBarLabel`) and the
//  Settings live preview (`MenuBarLivePreview`) so the two stay
//  visually identical.
//
//  Architecture
//  ============
//  Every segment renders as a horizontal pair:
//
//     ┌────────┬────────────────┐
//     │ label  │ value          │
//     └────────┴────────────────┘
//
//  The two halves are described by orthogonal templates so adding a
//  new segment only requires picking from existing options:
//
//   * `LabelTemplate`  — how the leading abbreviation is drawn:
//       - `.horizontal` for percent/rate segments (e.g. "CPU 45%")
//       - `.verticalGlyphs` for graph segments (stacked single letters
//         beside a mini chart)
//
//   * `ValueTemplate`  — how the trailing value is drawn:
//       - `.percent(MetricKind)`       single integer percent + "%"
//       - `.percentWithIndicator(...)` percent plus a state glyph
//         (battery charging/plugged)
//       - `.dualRateStacked(prefix:, MetricKind, MetricKind)` two
//         lines of fixed-width short rates ("↓123K" / "↑ 12K" or
//         "R 1.2M" / "W  45K")
//       - `.miniBarChart(MetricKind, tint:, autoscale:)` a single
//         metric history
//       - `.miniBarChartCombined(MetricKind, MetricKind, tint:)` two
//         histories summed into one chart (NET in+out, DSK r+w)
//
//  All sizes live in `SegmentMetrics`. Every template renders into a
//  fixed-width box so the rasterised menu-bar image keeps a constant
//  width regardless of metric values — this is the whole point of the
//  refactor: number/rate jitter no longer reflows the status bar.
//

import PeakmonCore
import SwiftUI

// MARK: - Sizing constants

/// Width and height budget shared by every segment block. Centralised
/// so visual tuning happens in one place; widening one column does
/// not silently push other columns around.
enum SegmentMetrics {
    /// Min width of the horizontal leading label ("CPU", "MEM", "NET",
    /// "DSK", "BAT", "GPU") rendered at 11pt medium. `MEM` is the
    /// widest 3-letter abbreviation we ship and overflows a strict
    /// 26pt slot — the block widens slightly for it.
    static let horizontalLabelMinWidth: CGFloat = 26
    /// Slot width for a single percent value at 11pt monospaced.
    /// Fits "100%" with a hair of trailing slack.
    static let percentValueWidth: CGFloat = 30
    /// Slot width for the 4-character rate column (e.g. "1.2M").
    static let rateValueWidth: CGFloat = 32
    /// Width of the leading prefix glyph column inside a stacked-rate
    /// row ("\u{2193}", "\u{2191}", "R", "W"). Kept fixed so the
    /// glyph stays glued to the same column regardless of how many
    /// digits the trailing rate takes up.
    static let ratePrefixWidth: CGFloat = 7
    /// Inline bar chart width.
    static let chartWidth: CGFloat = 38
    /// Inline bar chart height — almost fills the 22pt block.
    static let chartHeight: CGFloat = 18
    /// Horizontal gap between label and value columns inside a block.
    static let columnSpacing: CGFloat = 3
    /// Extra trailing room reserved by `.percentWithIndicator` for the
    /// status glyph (bolt/plug).
    static let indicatorWidth: CGFloat = 10
}

// MARK: - Templates

/// How a segment's leading abbreviation is drawn.
enum LabelTemplate {
    case horizontal
    case verticalGlyphs
}

/// How a segment's value column is drawn. Each case owns the metric
/// kinds it reads, so the template alone is enough to render — the
/// view never has to switch on `MenuBarSegment` again.
enum ValueTemplate {
    case percent(MetricKind)
    case percentWithIndicator(MetricKind, indicator: IndicatorKind)
    case dualRateStacked(prefixes: (String, String), MetricKind, MetricKind)
    case miniBarChart(MetricKind, tintRole: TintRole, autoscale: Bool)
    case miniBarChartCombined(MetricKind, MetricKind, tintRole: TintRole)
}

/// Status glyph kinds emitted by `percentWithIndicator`. Currently only
/// the battery power-source flag is modelled — extend this enum when
/// new "percent + state" segments arrive.
enum IndicatorKind {
    case batteryPowerSource
}

/// Logical accent role used by a value template; resolved at draw
/// time against the user's per-card tint AppStorage.
enum TintRole {
    case cpu, memory, disk, network, gpu
}

// MARK: - Segment block

struct MenuBarSegmentBlock: View {
    let segment: MenuBarSegment
    let store: MetricsStore
    let cpuTint: Color
    let memoryTint: Color
    let diskTint: Color
    let networkTint: Color
    let gpuTint: Color

    var body: some View {
        let template = segment.template
        HStack(spacing: SegmentMetrics.columnSpacing) {
            label(template.label)
            value(template.value)
        }
    }

    @ViewBuilder
    private func label(_ template: LabelTemplate) -> some View {
        switch template {
        case .horizontal:
            // `M` is wider than `C`/`G`, so we let the label claim
            // its natural width via `fixedSize` and only enforce a
            // minimum. Without `fixedSize` plus `lineLimit(1)`, `MEM`
            // would wrap inside a strict 26pt slot at 11pt medium.
            Text(segment.shortName)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: SegmentMetrics.horizontalLabelMinWidth, alignment: .leading)
        case .verticalGlyphs:
            VerticalGlyphLabel(text: segment.shortName)
        }
    }

    @ViewBuilder
    private func value(_ template: ValueTemplate) -> some View {
        switch template {
        case let .percent(kind):
            percentView(kind: kind)
        case let .percentWithIndicator(kind, indicatorKind):
            percentWithIndicatorView(kind: kind, indicatorKind: indicatorKind)
        case let .dualRateStacked(prefixes, kindA, kindB):
            dualRateView(prefixes: prefixes, kindA: kindA, kindB: kindB)
        case let .miniBarChart(kind, tintRole, autoscale):
            chartView(
                samples: store.history(for: kind),
                tint: resolveTint(tintRole),
                maxValue: autoscale ? nil : 100,
            )
        case let .miniBarChartCombined(kindA, kindB, tintRole):
            chartView(
                samples: Self.combinedHistory(store: store, kindA: kindA, kindB: kindB),
                tint: resolveTint(tintRole),
                maxValue: nil,
            )
        }
    }

    // MARK: Value renderers

    @ViewBuilder
    private func percentView(kind: MetricKind) -> some View {
        let v = store.latest(for: kind)?.value ?? 0
        Text("\(Int(v.rounded()))%")
            .frame(width: SegmentMetrics.percentValueWidth, alignment: .trailing)
    }

    @ViewBuilder
    private func percentWithIndicatorView(kind: MetricKind, indicatorKind: IndicatorKind) -> some View {
        let v = store.latest(for: kind)?.value ?? 0
        HStack(spacing: 1) {
            Text("\(Int(v.rounded()))%")
            indicatorView(indicatorKind)
                .font(.system(size: 8, weight: .bold))
                .frame(width: SegmentMetrics.indicatorWidth, alignment: .leading)
        }
        .frame(
            width: SegmentMetrics.percentValueWidth + SegmentMetrics.indicatorWidth,
            alignment: .trailing,
        )
    }

    @ViewBuilder
    private func indicatorView(_ kind: IndicatorKind) -> some View {
        switch kind {
        case .batteryPowerSource:
            let source = store.latest(for: .batteryPowerSource).map {
                BatteryPowerSource(metricValue: $0.value)
            } ?? .onBattery
            switch source {
            case .charging:
                Image(systemName: "bolt.fill")
            case .acPlugged:
                Image(systemName: "powerplug.fill")
            case .onBattery:
                Color.clear
            }
        }
    }

    @ViewBuilder
    private func dualRateView(prefixes: (String, String), kindA: MetricKind, kindB: MetricKind) -> some View {
        let a = store.latest(for: kindA)?.value ?? 0
        let b = store.latest(for: kindB)?.value ?? 0
        VStack(alignment: .leading, spacing: 0) {
            rateRow(prefix: prefixes.0, value: a)
            rateRow(prefix: prefixes.1, value: b)
        }
        .font(.system(size: 8, weight: .medium).monospacedDigit())
        .frame(width: SegmentMetrics.rateValueWidth, alignment: .leading)
    }

    /// One row of a `dualRateStacked` value: a fixed-width prefix
    /// glyph column followed by a fixed-width right-aligned rate
    /// column. Splitting the two prevents the prefix from drifting
    /// horizontally as the digit string shortens (e.g. when a rate
    /// drops from "1.2M" to "  9K").
    @ViewBuilder
    private func rateRow(prefix: String, value: Double) -> some View {
        HStack(spacing: 0) {
            Text(prefix)
                .frame(width: SegmentMetrics.ratePrefixWidth, alignment: .leading)
            Text(Self.shortRate(value))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func chartView(samples: [MetricSample], tint: Color, maxValue: Double?) -> some View {
        MenuBarBarChart(
            samples: samples,
            tint: tint,
            maxValue: maxValue,
            size: .init(width: SegmentMetrics.chartWidth, height: SegmentMetrics.chartHeight),
        )
        .frame(width: SegmentMetrics.chartWidth, height: SegmentMetrics.chartHeight)
    }

    private func resolveTint(_ role: TintRole) -> Color {
        switch role {
        case .cpu: cpuTint
        case .memory: memoryTint
        case .disk: diskTint
        case .network: networkTint
        case .gpu: gpuTint
        }
    }

    // MARK: Helpers

    /// Fixed-width 4-character rate string: pads with leading
    /// spaces so "  0K", " 12K", "999K", "1.2M", " 12M" all occupy
    /// exactly 4 monospaced cells. Removes width jitter when
    /// network/disk activity ramps across unit boundaries.
    static func shortRate(_ bytesPerSecond: Double) -> String {
        let kib = bytesPerSecond / 1024
        if kib < 1 { return "  0K" }
        if kib < 1000 { return String(format: "%3dK", Int(kib)) }
        let mib = kib / 1024
        if mib < 10 { return String(format: "%.1fM", mib) }
        if mib < 1000 { return String(format: "%3dM", Int(mib)) }
        let gib = mib / 1024
        return String(format: "%.1fG", gib)
    }

    static func combinedHistory(
        store: MetricsStore,
        kindA: MetricKind,
        kindB: MetricKind,
    ) -> [MetricSample] {
        let lhs = store.history(for: kindA)
        let rhs = store.history(for: kindB)
        let count = min(lhs.count, rhs.count)
        guard count > 0 else { return [] }
        return (0 ..< count).map { index in
            let left = lhs[lhs.count - count + index]
            let right = rhs[rhs.count - count + index]
            return MetricSample(
                kind: kindA,
                unit: left.unit,
                value: left.value + right.value,
                timestamp: left.timestamp,
            )
        }
    }
}

// MARK: - Segment -> Template mapping

extension MenuBarSegment {
    /// 3-character abbreviation used as the leading text label. Same
    /// letters for both percent and graph variants so the user can
    /// visually pair them up.
    var shortName: String {
        switch self {
        case .cpuPercent, .cpuGraph: "CPU"
        case .memoryPercent, .memoryGraph: "MEM"
        case .networkRate, .networkGraph: "NET"
        case .diskRate, .diskGraph: "DSK"
        case .batteryPercent: "BAT"
        case .gpuPercent, .gpuGraph: "GPU"
        }
    }

    /// Composite render description. Adding a new segment is a matter
    /// of adding a case here that returns one of the existing
    /// (`LabelTemplate`, `ValueTemplate`) pairs.
    var template: (label: LabelTemplate, value: ValueTemplate) {
        switch self {
        case .cpuPercent:
            (.horizontal, .percent(.cpuTotal))
        case .cpuGraph:
            (.verticalGlyphs, .miniBarChart(.cpuTotal, tintRole: .cpu, autoscale: false))
        case .memoryPercent:
            (.horizontal, .percent(.memoryPressure))
        case .memoryGraph:
            (.verticalGlyphs, .miniBarChart(.memoryPressure, tintRole: .memory, autoscale: false))
        case .networkRate:
            (.horizontal, .dualRateStacked(prefixes: ("\u{2193}", "\u{2191}"), .netInRate, .netOutRate))
        case .networkGraph:
            (.verticalGlyphs, .miniBarChartCombined(.netInRate, .netOutRate, tintRole: .network))
        case .diskRate:
            (.horizontal, .dualRateStacked(prefixes: ("R", "W"), .diskReadRate, .diskWriteRate))
        case .diskGraph:
            (.verticalGlyphs, .miniBarChartCombined(.diskReadRate, .diskWriteRate, tintRole: .disk))
        case .batteryPercent:
            (
                .horizontal,
                .percentWithIndicator(.batteryLevel, indicator: .batteryPowerSource)
            )
        case .gpuPercent:
            (.horizontal, .percent(.gpuUtilization))
        case .gpuGraph:
            (.verticalGlyphs, .miniBarChart(.gpuUtilization, tintRole: .gpu, autoscale: false))
        }
    }
}

// MARK: - Vertical glyph label

/// Renders a short string as a vertical stack of single glyphs.
/// Each glyph claims its natural intrinsic size so SwiftUI never
/// wraps it onto two lines; a negative `VStack` spacing pulls the
/// rows together to fit inside the 22pt block.
private struct VerticalGlyphLabel: View {
    let text: String

    private static let glyphFontSize: CGFloat = 7
    /// Explicit per-glyph slot width. Sized to comfortably hold `M`
    /// at 7pt semibold without clipping.
    private static let glyphWidth: CGFloat = 10

    var body: some View {
        VStack(spacing: -2) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, character in
                Text(String(character))
                    .font(.system(size: Self.glyphFontSize, weight: .bold, design: .monospaced))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(width: Self.glyphWidth)
            }
        }
    }
}
