//
//  DashboardCPUCard.swift
//  Peakmon
//
//  Dashboard CPU panel — default-full information, no second-
//  level disclosure. The single body lays out:
//
//    Top row     — headline % + USI bar + chips on the left,
//                  trend sparkline on the right.
//    Per-core    — 1 Hz `PerCoreCPUReader` driven bar chart.
//
//  Footer carries load average (1/5/15 min) and CPU temperature.
//
//  Why no embedded process table: Top processes graduated to a
//  dedicated full-width panel at the bottom of the dashboard
//  (see `DashboardProcessesPanel`). Duplicating the table inside
//  the CPU card would waste vertical real-estate and force the
//  CPU card much taller than the Memory card next to it, which
//  re-introduces the same "ragged grid" symptom we just fixed.
//
//  Performance: PerCoreCPUReader ticks every second through a
//  `TimelineView`; cost is one Mach call for `host_processor_info`
//  plus a small diff loop.
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
        // Per-core sampler driven by a `TimelineView`. Wrapping
        // the card keeps every card's data plumbing in one place;
        // SwiftUI re-evaluates only the values that change.
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
                PerCoreBarChart(values: perCoreUsage, tint: tint)
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

/// Drives the per-core reader at 1 Hz from a `TimelineView` so
/// the sampler ticks live alongside the rest of the dashboard.
/// Pulled out as a `ViewModifier` so the body composition above
/// stays focused on layout rather than timing plumbing.
private struct PerCoreSamplerModifier: ViewModifier {
    let reader: PerCoreCPUReader
    @Binding var usage: [Double]

    func body(content: Content) -> some View {
        content
            .onAppear {
                // First call primes the baseline; second produces
                // the first real values so users don't stare at
                // a "Sampling…" placeholder for a whole second.
                _ = reader.sample()
                usage = reader.sample()
            }
            .background {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Color.clear.onChange(of: context.date) { _, _ in
                        usage = reader.sample()
                    }
                }
            }
    }
}

/// Vertical bar chart for per-core utilisation. Drawn from
/// `GeometryReader + HStack(Rectangle)` rather than SwiftCharts
/// because the data is just N values in 0…1 and the chart-axis
/// overhead of a full Chart is wasted here.
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
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.quaternary)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(barTint(for: value).gradient)
                                .frame(height: max(2, proxy.size.height * CGFloat(value)))
                                // No animation: with 10–20 cores all
                                // running a 0.3s smooth interpolator
                                // every tick, the Core Animation
                                // commit pass burns visible CPU on
                                // intermediate frames the user never
                                // really perceives anyway. A direct
                                // step matches Activity Monitor's
                                // per-core graph and is essentially
                                // free.
                        }
                        .frame(width: barWidth)
                    }
                }
            }
        }
    }

    private func barTint(for value: Double) -> Color {
        if value < 0.7 { return tint }
        if value < 0.9 { return .yellow }
        return .red
    }
}
