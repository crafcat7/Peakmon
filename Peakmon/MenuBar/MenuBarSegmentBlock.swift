//
//  MenuBarSegmentBlock.swift
//  Peakmon
//
//  Template-driven rendering for a single `MenuBarSegment`. Used by
//  both the rasterised system menu-bar label (`MenuBarLabel`) and the
//  Settings live preview (`MenuBarLivePreview`) so layout and value
//  formatting stay identical while each caller supplies the graph
//  tints appropriate to its surface.
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
//       - `.compactHorizontal` for content-hugging labels (e.g. "ISS")
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
//       - `.miniBarChartWithFallback(...)` primary history with a
//         secondary metric used when the primary has no positive data
//       - `.miniBarChartCombined(MetricKind, MetricKind, tint:)` two
//         histories summed into one chart (NET in+out, DSK r+w)
//
//  Size budgets live in `SegmentMetrics`; percentage values use a hidden
//  three-digit reference view so their intrinsic column stays fixed while
//  the rasterised menu-bar image remains stable across metric values — this
//  is the whole point of the refactor: number/rate jitter no longer reflows
//  the status bar.
//

import PeakmonCore
import PeakmonUI
import SwiftUI

// MARK: - Sizing constants

/// Width and height budget shared by every segment block. Centralised
/// so visual tuning happens in one place; widening one column does
/// not silently push other columns around.
enum SegmentMetrics {
    /// Number of recent bars rendered for every menu-bar mini chart.
    static let miniChartBarCount: Int = 18
    /// Slot width for a watts value at 11pt monospaced. Fits "999W"
    /// and "9.9W" — single decimal under 10W, integer thereafter.
    static let wattsValueWidth: CGFloat = 34
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
    case compactHorizontal
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
    case miniBarChartWithFallback(primary: MetricKind, fallback: MetricKind, tintRole: TintRole, autoscale: Bool)
    case miniBarChartCombined(MetricKind, MetricKind, tintRole: TintRole)
    case watts(MetricKind)
    case wattsWithFallback(primary: MetricKind, fallback: MetricKind)
    case issueStatus
}

/// Status glyph kinds emitted by `percentWithIndicator`. Currently only
/// the battery power-source flag is modelled — extend this enum when
/// new "percent + state" segments arrive.
enum IndicatorKind {
    case batteryPowerSource
}

/// Logical accent role used by a graph value template; resolved at
/// draw time against the caller-provided tint map.
///
/// `TintRole` is intentionally a strict subset of `CardTintSlot` —
/// the menu bar never references thermal/fan/battery accents — so
/// the type system rules out a `.thermal` or `.fan` segment by
/// construction. `slot` projects the role back into `CardTintSlot`
/// for storage lookups.
enum TintRole {
    case cpu, memory, disk, network, gpu, power

    var slot: CardTintSlot {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .disk: .disk
        case .network: .network
        case .gpu: .gpu
        case .power: .power
        }
    }
}

// MARK: - Signature inputs

/// One quantised data dependency of a `ValueTemplate`. The
/// menu-bar rasteriser cache compares an array of these per
/// segment, so identical inputs short-circuit a re-render even
/// when the underlying `Double`s jitter below the display
/// granularity. Encoding the dependency *here*, on the same enum
/// that drives rendering, guarantees the cache key cannot drift
/// away from what the value column actually shows.
enum SignatureInput: Equatable {
    /// Percent-style scalar quantised to integer percentage
    /// points (`round`). Used by `.percent` / `.percentWithIndicator`.
    case percent(MetricKind)
    /// Byte/second rate quantised through `MenuBarLabelSignature`'s
    /// `bucketRate`, matching the exact buckets `shortRate`
    /// renders to. Used by `.dualRateStacked`.
    case rate(MetricKind)
    /// Percent-style 18-sample history hashed at integer
    /// resolution. Used by `.miniBarChart` for non-rate metrics.
    case history(MetricKind)
    /// History where the primary metric is preferred but a fallback
    /// metric renders when the primary has no positive samples.
    case historyWithFallback(primary: MetricKind, fallback: MetricKind)
    /// Rate-style 18-sample history hashed through `bucketRate`
    /// per sample. Used by `.miniBarChart` for rate metrics and
    /// by `.miniBarChartCombined`.
    case rateHistory(MetricKind)
    /// Unquantised scalar passed straight to `latestValues`. Used
    /// for opaque state flags like the battery power source where
    /// any value change should invalidate the cache.
    case raw(MetricKind)
    /// Watts scalar quantised to the granularity `shortWatts`
    /// actually renders: 0.1 W under 10 W, 1 W thereafter.
    case watts(MetricKind)
    /// Watts scalar using the same primary/fallback decision as rendering.
    case wattsWithFallback(primary: MetricKind, fallback: MetricKind)
    /// Count and severity of recent shared History anomaly events.
    case issueStatus
}

extension ValueTemplate {
    /// Data dependencies of this template's rendering, in stable
    /// order. `MenuBarLabelSignature.make` consumes the resulting
    /// list to build the cache key without ever switching on
    /// `MenuBarSegment` directly — so adding a new segment never
    /// requires the signature builder to learn about it, only the
    /// template enum.
    var signatureInputs: [SignatureInput] {
        switch self {
        case let .percent(kind):
            [.percent(kind)]
        case let .percentWithIndicator(kind, indicator):
            switch indicator {
            case .batteryPowerSource:
                [.percent(kind), .raw(.batteryPowerSource)]
            }
        case let .dualRateStacked(_, a, b):
            [.rate(a), .rate(b)]
        case let .miniBarChart(kind, _, _):
            if Self.isRateKind(kind) {
                [.rateHistory(kind)]
            } else if kind == .memoryPressure {
                [.history(kind), .percent(.memoryPressureLevel)]
            } else {
                [.history(kind)]
            }
        case let .miniBarChartWithFallback(primary, fallback, _, _):
            [.historyWithFallback(primary: primary, fallback: fallback)]
        case let .miniBarChartCombined(a, b, _):
            [.rateHistory(a), .rateHistory(b)]
        case let .watts(kind):
            [.watts(kind)]
        case let .wattsWithFallback(primary, fallback):
            [.wattsWithFallback(primary: primary, fallback: fallback)]
        case .issueStatus:
            [.issueStatus]
        }
    }

    /// Whitelist of metric kinds whose history should be bucketed
    /// through `bucketRate`. Kept here (rather than on `MetricKind`)
    /// because the bucketing strategy is a *display* concern owned
    /// by `MenuBarSegmentBlock`, not a property of the metric
    /// itself.
    private static func isRateKind(_ kind: MetricKind) -> Bool {
        switch kind {
        case .netInRate, .netOutRate, .diskReadRate, .diskWriteRate: true
        default: false
        }
    }
}

// MARK: - Segment block

struct MenuBarSegmentBlock: View {
    let segment: MenuBarSegment
    let store: MetricsStore
    let tints: [CardTintSlot: Color]
    var historyIssuesStore: HistoryIssuesStore? = nil

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
            // Let each static abbreviation claim its natural width. The
            // fixed-size label is stable for a given segment and avoids
            // reserving extra width for narrower labels such as `CPU`.
            Text(segment.shortName)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        case .compactHorizontal:
            Text(segment.shortName)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 2)
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
                samples: store.historySuffix(for: kind, limit: SegmentMetrics.miniChartBarCount),
                tint: effectiveTint(for: kind, base: resolveTint(tintRole)),
                maxValue: autoscale ? nil : 100,
            )
        case let .miniBarChartWithFallback(primary, fallback, tintRole, autoscale):
            let kind = fallbackKind(primary: primary, fallback: fallback)
            chartView(
                samples: store.historySuffix(for: kind, limit: SegmentMetrics.miniChartBarCount),
                tint: effectiveTint(for: kind, base: resolveTint(tintRole)),
                maxValue: autoscale ? nil : 100,
            )
        case let .miniBarChartCombined(kindA, kindB, tintRole):
            chartView(
                samples: Self.combinedHistory(store: store, kindA: kindA, kindB: kindB),
                tint: resolveTint(tintRole),
                maxValue: nil,
            )
        case let .watts(kind):
            wattsView(kind: kind)
        case let .wattsWithFallback(primary, fallback):
            wattsView(kind: fallbackKind(primary: primary, fallback: fallback))
        case .issueStatus:
            issueStatusView
        }
    }

    // MARK: Value renderers

    @ViewBuilder
    private func percentView(kind: MetricKind) -> some View {
        let v = store.latest(for: kind)?.value ?? 0
        MenuBarPercentValue(text: MenuBarPercentFormatting.string(for: v))
    }

    @ViewBuilder
    private func wattsView(kind: MetricKind) -> some View {
        let v = store.latest(for: kind)?.value ?? 0
        Text(Self.shortWatts(v))
            .frame(width: SegmentMetrics.wattsValueWidth, alignment: .trailing)
    }

    private var issueStatusView: some View {
        let count = historyIssuesStore?.recentEvents.count ?? 0
        return HStack(spacing: 3) {
            Image(systemName: count == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(count == 0 ? "OK" : "\(count)")
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func fallbackKind(primary: MetricKind, fallback: MetricKind) -> MetricKind {
        let primaryValue = store.latest(for: primary)?.value ?? 0
        return primaryValue > 0 ? primary : fallback
    }

    @ViewBuilder
    private func percentWithIndicatorView(kind: MetricKind, indicatorKind: IndicatorKind) -> some View {
        let v = store.latest(for: kind)?.value ?? 0
        HStack(spacing: 1) {
            MenuBarPercentValue(text: MenuBarPercentFormatting.string(for: v))
            indicatorView(indicatorKind)
                .font(.system(size: 8, weight: .bold))
                .frame(width: SegmentMetrics.indicatorWidth, alignment: .leading)
        }
        .fixedSize(horizontal: true, vertical: false)
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
            rasterize: false,
        )
        .frame(width: SegmentMetrics.chartWidth, height: SegmentMetrics.chartHeight)
    }

    private func resolveTint(_ role: TintRole) -> Color {
        tints[role.slot] ?? .primary
    }

    /// Returns the tint a graph column should paint with, after
    /// applying data-driven overrides. Today the only override is the
    /// macOS VM-pressure level on the memory graph; scalar text keeps
    /// the inherited status-bar foreground colour.
    private func effectiveTint(for kind: MetricKind, base: Color) -> Color {
        memoryPressureOverride(for: kind) ?? base
    }

    private func memoryPressureOverride(for kind: MetricKind) -> Color? {
        switch kind {
        case .memoryPressure, .memoryUsed, .memoryPressureLevel:
            break
        default:
            return nil
        }
        guard let level = store.latest(for: .memoryPressureLevel)?.value else {
            return nil
        }
        switch Int(level) {
        case 2: return .yellow
        case 4, 8: return .red
        default: return nil
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

    /// Fixed-width watts string. Single-decimal precision under
    /// 10 W (`9.9W`), integer precision thereafter (` 12W`, `999W`).
    /// Quantisation matches `MenuBarLabelSignature.bucketWatts` so
    /// the label cache keys stay aligned with what is actually drawn.
    static func shortWatts(_ watts: Double) -> String {
        let clamped = max(0, watts)
        if clamped < 10 { return String(format: "%.1fW", clamped) }
        return String(format: "%3.0fW", clamped)
    }

    static func combinedHistory(
        store: MetricsStore,
        kindA: MetricKind,
        kindB: MetricKind,
    ) -> [MetricSample] {
        let lhs = store.historySuffix(for: kindA, limit: SegmentMetrics.miniChartBarCount)
        let rhs = store.historySuffix(for: kindB, limit: SegmentMetrics.miniChartBarCount)
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

// MARK: - Segment descriptor

/// Single source of truth for everything `MenuBarSegment` exposes.
/// Adding a new segment now requires exactly two edits: a new case
/// on the enum and a new branch in `MenuBarSegment.descriptor`.
/// Title, system image, vertical-glyph abbreviation, render
/// template, and signature inputs all flow from this struct so
/// they cannot drift out of sync.
struct SegmentDescriptor {
    let title: String
    let systemImage: String
    let shortName: String
    let template: (label: LabelTemplate, value: ValueTemplate)
}

extension MenuBarSegment {
    /// Single switch holding the entire per-segment configuration.
    /// All other computed properties on this type forward into the
    /// descriptor, so the menu-bar rasteriser, the settings UI, and
    /// the cache-key builder never read divergent metadata.
    var descriptor: SegmentDescriptor {
        switch self {
        case .cpuPercent:
            SegmentDescriptor(
                title: "CPU %",
                systemImage: "cpu",
                shortName: "CPU",
                template: (.horizontal, .percent(.cpuTotal)),
            )
        case .cpuGraph:
            SegmentDescriptor(
                title: "CPU graph",
                systemImage: "cpu",
                shortName: "CPU",
                template: (.verticalGlyphs, .miniBarChart(.cpuTotal, tintRole: .cpu, autoscale: false)),
            )
        case .memoryPercent:
            SegmentDescriptor(
                title: "Memory %",
                systemImage: "memorychip",
                shortName: "MEM",
                template: (.horizontal, .percent(.memoryPressure)),
            )
        case .memoryGraph:
            SegmentDescriptor(
                title: "Memory graph",
                systemImage: "memorychip",
                shortName: "MEM",
                template: (.verticalGlyphs, .miniBarChart(.memoryPressure, tintRole: .memory, autoscale: false)),
            )
        case .networkRate:
            SegmentDescriptor(
                title: "Network ↓↑",
                systemImage: "network",
                shortName: "NET",
                template: (
                    .horizontal,
                    .dualRateStacked(prefixes: ("\u{2193}", "\u{2191}"), .netInRate, .netOutRate),
                ),
            )
        case .networkGraph:
            SegmentDescriptor(
                title: "Network graph",
                systemImage: "network",
                shortName: "NET",
                template: (
                    .verticalGlyphs,
                    .miniBarChartCombined(.netInRate, .netOutRate, tintRole: .network),
                ),
            )
        case .diskRate:
            SegmentDescriptor(
                title: "Disk R/W",
                systemImage: "internaldrive",
                shortName: "DSK",
                template: (
                    .horizontal,
                    .dualRateStacked(prefixes: ("R", "W"), .diskReadRate, .diskWriteRate),
                ),
            )
        case .diskGraph:
            SegmentDescriptor(
                title: "Disk graph",
                systemImage: "internaldrive",
                shortName: "DSK",
                template: (
                    .verticalGlyphs,
                    .miniBarChartCombined(.diskReadRate, .diskWriteRate, tintRole: .disk),
                ),
            )
        case .batteryPercent:
            SegmentDescriptor(
                title: "Battery %",
                systemImage: "battery.100percent",
                shortName: "BAT",
                template: (
                    .horizontal,
                    .percentWithIndicator(.batteryLevel, indicator: .batteryPowerSource),
                ),
            )
        case .gpuPercent:
            SegmentDescriptor(
                title: "GPU %",
                systemImage: "cpu.fill",
                shortName: "GPU",
                template: (.horizontal, .percent(.gpuUtilization)),
            )
        case .gpuGraph:
            SegmentDescriptor(
                title: "GPU graph",
                systemImage: "cpu.fill",
                shortName: "GPU",
                template: (
                    .verticalGlyphs,
                    .miniBarChart(.gpuUtilization, tintRole: .gpu, autoscale: false),
                ),
            )
        case .powerWatts:
            SegmentDescriptor(
                title: "Power W",
                systemImage: "bolt.fill",
                shortName: "PWR",
                template: (.horizontal, .wattsWithFallback(primary: .powerSystem, fallback: .powerPackage)),
            )
        case .powerGraph:
            SegmentDescriptor(
                title: "Power graph",
                systemImage: "bolt.fill",
                shortName: "PWR",
                template: (
                    .verticalGlyphs,
                    .miniBarChartWithFallback(
                        primary: .powerSystem,
                        fallback: .powerPackage,
                        tintRole: .power,
                        autoscale: true,
                    ),
                ),
            )
        case .recentIssues:
            SegmentDescriptor(
                title: "Recent issues",
                systemImage: "exclamationmark.triangle.fill",
                shortName: "ISS",
                template: (.compactHorizontal, .issueStatus),
            )
        }
    }

    /// 3-character abbreviation used as the leading text label. Same
    /// letters for both percent and graph variants so the user can
    /// visually pair them up.
    var shortName: String { descriptor.shortName }

    /// Composite render description.
    var template: (label: LabelTemplate, value: ValueTemplate) { descriptor.template }
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
