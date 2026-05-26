//
//  DashboardCPUCard.swift
//  Peakmon
//
//  Dashboard CPU panel with an inline drill-down. The card has
//  two visual states driven by a tap on the card chrome:
//
//    • Collapsed (default): headline number, user/system/idle
//      ratio bar, three coloured chips, a 200pt trend sparkline.
//      Visually richer than the popover CPUCard but still a
//      single-screen summary.
//
//    • Expanded: the same header stays in place; an extra block
//      slides in below containing a per-core utilisation grid
//      (driven by `PerCoreCPUReader`) and a top-N CPU process
//      list (driven by `ProcessesStore`). Click anywhere on the
//      header or the chevron to collapse again.
//
//  Why inline rather than push-navigation / sheet:
//    • Push-navigation breaks the "Dashboard surface" mental
//      model — the user is exploring multiple cards in parallel,
//      not drilling into a single workflow.
//    • Sheets dim the rest of the dashboard, blocking the very
//      thing the user wanted to compare against.
//    • Inline lets the drill-down sit *inside* the LazyVGrid
//      cell; SwiftUI reflows the grid automatically so neighbour
//      cards just push down.
//
//  Performance notes:
//    • The per-core reader only ticks while expanded; collapsing
//      calls `reader.reset()` to drop the baseline.
//    • The process list reads `ProcessesStore.latestProcesses`
//      which the existing collector refreshes at 0.5 Hz — no
//      additional sampling cost.
//

import PeakmonCore
import PeakmonUI
import SwiftUI

struct DashboardCPUCard: View {
    @Environment(MetricsStore.self) private var store
    @Environment(ProcessesStore.self) private var processesStore
    @Environment(\.cardSettings) private var cardSettings

    @ChartSeriesEnabled(.cpuTotal) private var cpuTotalEnabled
    @ChartSeriesEnabled(.cpuUser) private var cpuUserEnabled
    @ChartSeriesEnabled(.cpuSystem) private var cpuSystemEnabled

    @State private var isExpanded = false
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
        VStack(alignment: .leading, spacing: 16) {
            header
                .contentShape(.rect)
                .onTapGesture(perform: toggle)

            HStack(alignment: .top, spacing: 20) {
                summary
                    .frame(maxWidth: .infinity, alignment: .leading)
                trendChart
                    .frame(width: 200, height: 110)
            }

            if isExpanded {
                Divider()
                expandedDetail
                    // Pure opacity transition. Earlier drafts used
                    // `.opacity.combined(with: .move(edge: .top))`
                    // but the move portion let the per-core grid
                    // visibly slide *over* the divider during the
                    // first ~80ms of the animation — looked like
                    // a Z-order bug. Fading in place lets the
                    // outer VStack's height animation carry all
                    // the motion, which the human eye reads as a
                    // single coordinated reveal.
                    .transition(.opacity)
            }

            Divider()
            bottomRow
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.gray.opacity(0.18), lineWidth: 0.5)
        }
        // `.clipShape` rather than `.clipped()` because the latter
        // ignores the rounded corner radius and would let the
        // drill-down briefly poke past the card's curved edges
        // mid-animation on the first frame after the height
        // change is committed.
        .clipShape(.rect(cornerRadius: 14))
        .animation(.smooth(duration: 0.32), value: isExpanded)
    }

    // MARK: - Header (always visible, tappable)

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cpu")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .padding(7)
                .background(tint.opacity(0.15), in: .rect(cornerRadius: 7))

            Text("CPU")
                .font(.headline)

            Spacer()

            // Discoverability hint: the chevron rotates 90° when
            // expanded, the same idiom DisclosureGroup uses, so
            // users intuit "this row is openable" without copy.
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.smooth(duration: 0.25), value: isExpanded)
        }
    }

    // MARK: - Collapsed summary

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

    /// Stacked horizontal user / system / idle bar — visual
    /// analogue of the three textual percentages below it. Uses
    /// `GeometryReader` so the widths sum exactly to the
    /// available width rather than relying on HStack ratio
    /// approximations.
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

    // MARK: - Expanded detail

    /// Drill-down content: per-core grid + top CPU processes.
    /// The whole block is wrapped in a `TimelineView` so the
    /// per-core reader ticks at 1 Hz only while expanded.
    private var expandedDetail: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 16) {
                perCoreSection
                topProcessesSection
            }
            // Drive the @State usage array off the timeline tick.
            // Using `.onChange` of the context date keeps the
            // sample call inside the view update phase — cheap
            // because the reader is sub-microsecond.
            .onChange(of: context.date) { _, _ in
                perCoreUsage = perCoreReader.sample()
            }
            .onAppear {
                // First sample primes the baseline; second tick
                // produces the first real values. We trigger an
                // immediate prime so the user doesn't wait a full
                // second to see anything.
                _ = perCoreReader.sample()
                perCoreUsage = perCoreReader.sample()
            }
        }
    }

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
                PerCoreBarChart(values: perCoreUsage, tint: tint)
                    .frame(height: 70)
            }
        }
    }

    private var topProcessesSection: some View {
        // Take the top 8 CPU consumers. The ProcessesStore
        // already pre-sorts descending by CPU.
        let top = Array(processesStore.latestProcesses.prefix(8))

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Top processes by CPU")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(top.count) of \(processesStore.latestProcesses.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if top.isEmpty {
                Text("Collecting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 4) {
                    headerRow
                    ForEach(top) { snapshot in
                        processRow(snapshot)
                    }
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("Process")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("PID")
                .frame(width: 60, alignment: .trailing)
            Text("CPU%")
                .frame(width: 70, alignment: .trailing)
            Text("Memory")
                .frame(width: 80, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
    }

    private func processRow(_ p: ProcessSnapshot) -> some View {
        HStack(spacing: 8) {
            Text(p.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(p.pid))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
            Text(String(format: "%.1f%%", p.cpuPercent))
                .font(.caption.monospacedDigit())
                .foregroundStyle(cpuRowTint(p.cpuPercent))
                .frame(width: 70, alignment: .trailing)
            Text(formatBytes(p.memoryBytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
        .font(.caption)
    }

    /// Process CPU% tinting matches `top`/Activity Monitor
    /// expectations: a single thread fully saturating one core
    /// is normal at 100 %; multi-threaded saturation past 200 %
    /// starts to deserve the user's attention.
    private func cpuRowTint(_ cpu: Double) -> Color {
        switch cpu {
        case ..<10: .secondary
        case ..<50: .primary
        case ..<150: .orange
        default: .red
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }

    // MARK: - Footer (always visible)

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
        switch celsius {
        case ..<60: .secondary
        case ..<80: .primary
        case ..<95: .yellow
        default: .red
        }
    }

    // MARK: - Helpers

    private func toggle() {
        isExpanded.toggle()
        if !isExpanded {
            // Drop the baseline so the next expansion arms fresh
            // — otherwise we'd diff against a stale snapshot that
            // could be minutes old.
            perCoreReader.reset()
            perCoreUsage = []
        }
    }

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

/// Vertical bar chart for per-core utilisation, drawn as a row of
/// equally-spaced bars. Implemented from scratch (rather than via
/// SwiftCharts) because the data is just N floats in 0...1 and a
/// `GeometryReader + HStack(Rectangle)` is half the code with
/// none of the chart-axis overhead.
private struct PerCoreBarChart: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let count = max(values.count, 1)
            let spacing: CGFloat = 4
            let barWidth = max(2, (proxy.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    VStack(spacing: 2) {
                        ZStack(alignment: .bottom) {
                            // Track that fills the slot so all
                            // bars visually share the same
                            // baseline-to-ceiling extent — makes
                            // a low-load row much easier to read.
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.quaternary)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(barTint(for: value).gradient)
                                .frame(height: max(2, proxy.size.height * CGFloat(value)))
                                .animation(.smooth(duration: 0.3), value: value)
                        }
                        .frame(width: barWidth)
                    }
                }
            }
        }
    }

    /// Bar colour follows the same load semantic as the rest of
    /// the dashboard: tint until 70 %, yellow up to 90 %, red at
    /// saturation. Keeps a glance read across 8/12/16 bars cheap.
    private func barTint(for value: Double) -> Color {
        switch value {
        case ..<0.7: tint
        case ..<0.9: .yellow
        default: .red
        }
    }
}
