//
//  DashboardCPUCard.swift
//  Peakmon
//
//  Dashboard CPU panel — default-full information, no second-level
//  disclosure. Layout:
//
//    Top      — dominant utilisation + USI bar + chips.
//    Per-core — low-cadence E/P core utilisation bars.
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

    @State private var perCoreReader = PerCoreCPUReader()
    @State private var perCoreUsage: [Double] = []
    @State private var loadAverage = LoadAverageReader.current()

    private var tint: Color { cardSettings.tint(.cpu) }

    private var total: Double { store.value(for: .cpuTotal) }
    private var user: Double { store.value(for: .cpuUser) }
    private var system: Double { store.value(for: .cpuSystem) }
    private var cpuTemp: Double? {
        let value = store.latest(for: .thermalCPU)?.value ?? 0
        return value > 0 ? value : nil
    }

    var body: some View {
        DashboardMetricCard(
            title: "CPU",
            systemImage: "cpu",
            tint: tint,
            isEmphasized: true,
            headline: { summary },
            detail: { perCoreSection },
            footer: { bottomRow },
        )
        .modifier(PerCoreSamplerModifier(reader: perCoreReader, usage: $perCoreUsage))
        .task {
            loadAverage = LoadAverageReader.current()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                loadAverage = LoadAverageReader.current()
            }
        }
    }

    // MARK: - Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: dashboardSummarySpacing) {
            HStack(alignment: .firstTextBaseline, spacing: dashboardHeadlineUnitSpacing) {
                Text(String(format: "%.1f", total))
                    .font(.system(size: dashboardHeadlineNumberSize, weight: .bold, design: .rounded).monospacedDigit())
                Text("%")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            usiBar
                .frame(height: 6)
                .padding(.top, dashboardMetricBarTopPadding)

            HStack(spacing: 12) {
                MetricChipView(label: "user", value: String(format: "%.0f%%", user), color: .blue)
                MetricChipView(label: "system", value: String(format: "%.0f%%", system), color: .orange)
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

    // MARK: - Per-core

    @ViewBuilder
    private var perCoreSection: some View {
        Group {
            if perCoreUsage.isEmpty {
                PerCoreSamplingPlaceholder(tint: tint)
                    .frame(height: dashboardPerCoreChartHeight)
            } else {
                PerCoreBarChart(
                    values: perCoreUsage,
                    tint: tint,
                    topology: perCoreReader.topology,
                )
                .frame(height: dashboardPerCoreChartHeight)
            }
        }
        .padding(.top, dashboardDetailTopPadding)
    }

    // MARK: - Footer

    private var bottomRow: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Load average")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(
                    format: "%.2f · %.2f · %.2f",
                    loadAverage.oneMinute, loadAverage.fiveMinute, loadAverage.fifteenMinute,
                ))
                .font(.callout.monospacedDigit().weight(.medium))
            }

            Spacer()

            if let cpuTemp {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Temp")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Image(systemName: "thermometer.medium")
                            .font(.caption)
                            .foregroundStyle(DashboardFormatting.temperatureColor(cpuTemp))
                        Text("\(Int(cpuTemp.rounded()))°C")
                            .font(.callout.monospacedDigit().weight(.medium))
                            .foregroundStyle(DashboardFormatting.temperatureColor(cpuTemp))
                    }
                }
            }
        }
    }

}

private struct PerCoreSamplingPlaceholder: View {
    let tint: Color

    private let heights: [CGFloat] = [0.34, 0.48, 0.72, 0.42, 0.58, 0.82, 0.54, 0.68, 0.38, 0.62, 0.76, 0.46]

    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, fraction in
                Capsule()
                    .fill(tint.opacity(0.13))
                    .frame(maxWidth: .infinity)
                    .frame(height: dashboardPerCoreChartHeight * fraction)
            }
        }
        .overlay(alignment: .topTrailing) {
            Text("Sampling cores…")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityLabel("Sampling per-core utilisation")
    }
}

/// Drives the per-core reader at 0.25 Hz after a faster first refresh.
/// A two-sample rolling window smooths short bursts across ~8 s, and
/// the async task avoids `TimelineView` invalidating the CPU card on a
/// rigid schedule when the values did not visibly change.
private struct PerCoreSamplerModifier: ViewModifier {
    let reader: PerCoreCPUReader
    @Binding var usage: [Double]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let firstCadence: Duration = .seconds(2)
    private static let cadence: Duration = .seconds(4)
    private static let publishThreshold = 0.01
    private static let easedPublishFrameGap: Duration = .milliseconds(80)
    private static let easedPublishProgress = [0.45, 0.72, 0.90, 1.0]

    func body(content: Content) -> some View {
        content
            .onAppear {
                // Prime the baseline: first `sample()` returns []
                // (no prior snapshot); the schedule below fills the
                // window before the first UI tick.
                reader.reset()
                _ = reader.sample()
            }
            .onDisappear {
                reader.reset()
                usage = []
            }
            .task {
                var delay = Self.firstCadence
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: delay)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    delay = Self.cadence

                    let next = await MainActor.run {
                        reader.sample()
                        return reader.averagedSample()
                    }
                    guard !Task.isCancelled else { return }
                    await publish(next)
                }
            }
    }

    /// Softens the otherwise abrupt 4 s per-core update without
    /// enabling a display-link style implicit animation. Four small
    /// binding writes cost far less than ~30 rendered animation frames
    /// while still reading as an ease-out change.
    private func publish(_ next: [Double]) async {
        let current = await MainActor.run { usage }
        guard !Task.isCancelled, Self.shouldPublish(next, current: current) else { return }

        guard !reduceMotion, !current.isEmpty, current.count == next.count else {
            await MainActor.run {
                if !Task.isCancelled {
                    usage = next
                }
            }
            return
        }

        for (index, progress) in Self.easedPublishProgress.enumerated() {
            if index > 0 {
                do {
                    try await Task.sleep(for: Self.easedPublishFrameGap)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            let frame = Self.interpolate(from: current, to: next, progress: progress)
            await MainActor.run {
                if !Task.isCancelled {
                    usage = frame
                }
            }
        }
    }

    private static func shouldPublish(_ next: [Double], current: [Double]) -> Bool {
        guard !next.isEmpty else { return !current.isEmpty }
        guard next.count == current.count else { return true }
        return zip(next, current).contains { abs($0 - $1) >= publishThreshold }
    }

    private static func interpolate(from current: [Double], to next: [Double], progress: Double) -> [Double] {
        zip(current, next).map { start, end in
            start + (end - start) * progress
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
                let value = clamped(index < values.count ? values[index] : 0)
                let minimumScale = min(1, 2 / max(height, 1))
                let fillScale = max(CGFloat(value), minimumScale)
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.quaternary)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barTint(for: value, isPerformance: isPerformance).gradient)
                        .frame(maxHeight: .infinity)
                        .scaleEffect(x: 1, y: fillScale, anchor: .bottom)
                }
                .frame(width: barWidth, height: height)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private func clamped(_ value: Double) -> Double {
        max(0, min(1, value))
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
