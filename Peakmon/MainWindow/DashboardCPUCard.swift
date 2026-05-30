//
//  DashboardCPUCard.swift
//  Peakmon
//
//  Dashboard CPU panel — default-full information, no second-level
//  disclosure. Layout:
//
//    Top row  — headline % + USI bar + chips (left), trend
//               sparkline (right).
//    Per-core — `PerCoreCPUReader` bar chart (2 Hz internal
//               sampling, 4-sample rolling window ≈ 2 s smoothing,
//               published at 1 Hz), split into E-core / P-core
//               bands on Apple silicon (perf-level via sysctl).
//    Footer   — load average (1/5/15 min) + CPU temperature.
//
//  Top processes live in a dedicated full-width panel
//  (`DashboardProcessesPanel`), not here: an embedded table would
//  force the CPU card much taller than the Memory card beside it
//  and re-introduce the ragged-grid problem.
//

import PeakmonCore
import PeakmonUI
import SwiftUI

struct DashboardCPUCard: View {
    @Environment(MetricsStore.self) private var store
    @Environment(\.cardSettings) private var cardSettings

    @ChartSeriesEnabled(.cpuTotal) private var cpuTotalEnabled
    @ChartSeriesEnabled(.cpuUser) private var cpuUserEnabled
    @ChartSeriesEnabled(.cpuSystem) private var cpuSystemEnabled

    @State private var perCoreReader = PerCoreCPUReader()
    @State private var perCoreUsage: [Double] = []

    private var tint: Color { cardSettings.tint(.cpu) }

    private var total: Double { store.value(for: .cpuTotal) }
    private var user: Double { store.value(for: .cpuUser) }
    private var system: Double { store.value(for: .cpuSystem) }
    private var idle: Double { max(0, 100 - total) }
    private var cpuTemp: Double? {
        let value = store.latest(for: .thermalCPU)?.value ?? 0
        return value > 0 ? value : nil
    }

    var body: some View {
        DashboardMetricCard(
            title: "CPU",
            systemImage: "cpu",
            tint: tint,
            headline: { headlineRow },
            detail: { perCoreSection },
            footer: { bottomRow },
        )
        // Per-core sampler driven by a `TimelineView`, pulled into
        // a modifier to keep the body focused on layout.
        .modifier(PerCoreSamplerModifier(reader: perCoreReader, usage: $perCoreUsage))
    }

    private var headlineRow: some View {
        HStack(alignment: .top, spacing: 20) {
            summary
                .frame(maxWidth: .infinity, alignment: .leading)
            trendChart
                .frame(width: 200, height: 110)
        }
    }

    // MARK: - Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.1f", total))
                    .font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(value: total))
                    .animation(.smooth, value: total)
                Text("%")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text("Total utilisation")
                .font(.caption)
                .foregroundStyle(.secondary)

            usiBar
                .frame(height: 6)
                .padding(.top, 4)

            HStack(spacing: 14) {
                metricChip(label: "user", value: user, color: .blue)
                metricChip(label: "system", value: system, color: .orange)
                metricChip(label: "idle", value: idle, color: .secondary)
            }
        }
    }

    private var usiBar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let userW = width * (user / 100)
            let systemW = width * (system / 100)
            let idleW = max(0, width - userW - systemW)

            HStack(spacing: 0) {
                Rectangle().fill(Color.blue).frame(width: userW)
                Rectangle().fill(Color.orange).frame(width: systemW)
                Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: idleW)
            }
            .clipShape(.capsule)
        }
    }

    private func metricChip(label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(format: "%.0f%%", value))
                .font(.caption.monospacedDigit().weight(.medium))
        }
    }

    private var trendChart: some View {
        MetricSparklineView(
            series: sparklineSeries,
            yMin: 0,
            yMax: 100,
        )
    }

    // MARK: - Per-core

    private var perCoreSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Per-core utilisation")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !perCoreUsage.isEmpty {
                    Text("\(perCoreUsage.count) cores")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if perCoreUsage.isEmpty {
                Text("Sampling…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 70)
            } else {
                PerCoreBarChart(values: perCoreUsage, tint: tint, topology: perCoreReader.topology)
                    .frame(height: 70)
            }
        }
    }

    // MARK: - Footer

    private var bottomRow: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let load = LoadAverageReader.current()
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Load average")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(
                        format: "%.2f · %.2f · %.2f",
                        load.oneMinute, load.fiveMinute, load.fifteenMinute,
                    ))
                    .font(.callout.monospacedDigit().weight(.medium))
                }

                Spacer()

                if let cpuTemp {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("CPU temperature")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Image(systemName: "thermometer.medium")
                                .font(.caption)
                                .foregroundStyle(temperatureColor(cpuTemp))
                            Text("\(Int(cpuTemp.rounded()))°C")
                                .font(.callout.monospacedDigit().weight(.medium))
                                .foregroundStyle(temperatureColor(cpuTemp))
                        }
                    }
                }
            }
        }
    }

    private func temperatureColor(_ celsius: Double) -> Color {
        if celsius < 60 { return .secondary }
        if celsius < 80 { return .primary }
        if celsius < 95 { return .yellow }
        return .red
    }

    // MARK: - Sparkline series

    private var sparklineSeries: [SparklineSeries] {
        var lines: [SparklineSeries] = []
        if cpuTotalEnabled {
            lines.append(SparklineSeries(
                id: ChartSeries.cpuTotal.rawValue,
                samples: store.history(for: .cpuTotal),
                color: ChartSeries.cpuTotal.storedTint,
            ))
        }
        if cpuUserEnabled {
            lines.append(SparklineSeries(
                id: ChartSeries.cpuUser.rawValue,
                samples: store.history(for: .cpuUser),
                color: ChartSeries.cpuUser.storedTint,
            ))
        }
        if cpuSystemEnabled {
            lines.append(SparklineSeries(
                id: ChartSeries.cpuSystem.rawValue,
                samples: store.history(for: .cpuSystem),
                color: ChartSeries.cpuSystem.storedTint,
            ))
        }
        if lines.isEmpty {
            lines.append(SparklineSeries(
                id: "cpu.total",
                samples: store.history(for: .cpuTotal),
                color: tint,
            ))
        }
        return lines
    }
}

/// Drives the per-core reader at 2 Hz internally and publishes the
/// rolling-window average to the UI at 1 Hz. The short ~500 ms
/// inner window stops a single burst from filling it end-to-end —
/// what made the naive 1 Hz single-window reader binarise to ~0 %
/// or ~100 %. `windowSize = 4` means the published mean covers the
/// last ~2 s; the 1 Hz outer cadence is what the user sees. 2 Hz
/// (vs 4 Hz) halves the reader's Mach-call cost with no visible
/// difference. Pulled into a `ViewModifier` to keep the body on
/// layout, not timing.
private struct PerCoreSamplerModifier: ViewModifier {
    let reader: PerCoreCPUReader
    @Binding var usage: [Double]
    /// Counts inner 500 ms ticks; publishes every second tick. The
    /// first publish lands after 2 samples, so the user sees at
    /// least a 1 s mean rather than one 500 ms window's worst case.
    @State private var innerTickCount = 0

    func body(content: Content) -> some View {
        content
            .onAppear {
                // Prime the baseline: first `sample()` returns []
                // (no prior snapshot); the schedule below fills the
                // window before the first UI tick.
                _ = reader.sample()
            }
            .background {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    Color.clear.onChange(of: context.date) { _, _ in
                        // Always advance the window (keeps the mean
                        // fresh), publish only on even ticks.
                        reader.sample()
                        innerTickCount &+= 1
                        if innerTickCount % 2 == 0 {
                            usage = reader.averagedSample()
                        }
                    }
                }
            }
    }
}

/// Vertical bar chart for per-core utilisation, split into an
/// E-core band (left) and a P-core band (right) on Apple silicon.
/// On Intel / machines without a perf-level breakdown,
/// `firstPCoreIndex` is 0 and the chart collapses to a single
/// P-band. Hand-drawn (GeometryReader + Rectangles) rather than
/// SwiftCharts — the data is just N values in 0…1 and a full Chart
/// is wasted axis overhead.
private struct PerCoreBarChart: View {
    let values: [Double]
    let tint: Color
    let topology: PerCoreCPUReader.Topology

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                if topology.efficiencyCores > 0 {
                    bandHeader("E", count: topology.efficiencyCores)
                        .frame(width: bandWidth(for: topology.efficiencyCores), alignment: .leading)
                }
                bandHeader("P", count: topology.performanceCores)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            GeometryReader { proxy in
                // Reserve a fixed inter-band gap; the rest splits
                // by core count so each bar in either band stays
                // visually consistent.
                let bandGap: CGFloat = topology.efficiencyCores > 0 ? 12 : 0
                let usableWidth = proxy.size.width - bandGap
                let perCoreWidth = usableWidth / CGFloat(max(topology.totalCores, 1))
                HStack(spacing: bandGap) {
                    if topology.efficiencyCores > 0 {
                        bars(
                            range: 0..<topology.efficiencyCores,
                            width: perCoreWidth * CGFloat(topology.efficiencyCores),
                            isPerformance: false,
                            height: proxy.size.height,
                        )
                    }
                    bars(
                        range: topology.firstPCoreIndex..<topology.totalCores,
                        width: perCoreWidth * CGFloat(topology.performanceCores),
                        isPerformance: true,
                        height: proxy.size.height,
                    )
                }
            }
        }
    }

    /// Header-strip width for a band. Decorative only — the chart
    /// GeometryReader below is authoritative for bar positioning,
    /// so a flat 12pt-per-core estimate is enough to sit the label
    /// above its band.
    private func bandWidth(for count: Int) -> CGFloat {
        CGFloat(count) * 12
    }

    @ViewBuilder
    private func bandHeader(_ label: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("·")
                .foregroundStyle(.tertiary)
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    /// Renders one band's bars. `range` indexes into `values`;
    /// `isPerformance` controls tint intensity so E-cores read as
    /// quieter than P-cores even at the same utilisation.
    @ViewBuilder
    private func bars(range: Range<Int>, width: CGFloat, isPerformance: Bool, height: CGFloat) -> some View {
        let spacing: CGFloat = 4
        let count = range.count
        let barWidth = max(2, (width - spacing * CGFloat(max(count - 1, 0))) / CGFloat(max(count, 1)))
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(Array(range), id: \.self) { index in
                let value = index < values.count ? values[index] : 0
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.quaternary)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barTint(for: value, isPerformance: isPerformance).gradient)
                        .frame(height: max(2, height * CGFloat(value)))
                        // 300 ms linear tween between the 1 Hz
                        // published values, leaving ~700 ms of
                        // stillness that reads as a beat. Linear,
                        // not spring, to avoid overshoot frames
                        // indistinguishable from a clean step here.
                        .animation(.linear(duration: 0.3), value: value)
                }
                .frame(width: barWidth)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    /// Bar colour for a single core. P-cores get the card's full
    /// tint plus the yellow/red warning thresholds; E-cores get a
    /// muted variant so the eye registers "background, low-power"
    /// even when the bar happens to be tall. The threshold colours
    /// stay shared so a pegged E-core still alarms.
    private func barTint(for value: Double, isPerformance: Bool) -> Color {
        if value >= 0.9 { return .red }
        if value >= 0.7 { return .yellow }
        return isPerformance ? tint : tint.opacity(0.55)
    }
}
