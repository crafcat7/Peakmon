//
//  DashboardGPUCard.swift
//  Peakmon
//
//  GPU panel for the unified dashboard.
//
//    Collapsed — utilisation headline (the number users look at
//                first when asking "is the GPU busy"), trend
//                sparkline tinted on the gpu accent.
//    Expanded  — overlay sparkline of three series at once:
//                utilisation (%, primary axis 0–100), GPU
//                thermal (°C), GPU power (W). Each series gets
//                its own current-value chip beside the chart so
//                the chart legend doubles as a live readout.
//    Footer    — utilisation + GPU temp + GPU power triplet,
//                each labelled.
//
//  Why no per-engine breakdown (3D / Media / Compute): macOS
//  exposes per-engine utilisation via private IOReport channels
//  that require either Screen Recording entitlement (Mac Apps)
//  or root + tcc bypass. Both are out of scope for an ad-hoc
//  signed first-launch experience. The triple-series overlay
//  gives the user enough signal — utilisation answers "busy?",
//  thermal answers "hot?", power answers "drawing watts?".
//

import PeakmonCore
import PeakmonUI
import SwiftUI

struct DashboardGPUCard: View {
    @Environment(MetricsStore.self) private var store
    @Environment(\.cardSettings) private var cardSettings

    private var tint: Color { cardSettings.tint(.gpu) }

    private var util: Double { store.value(for: .gpuUtilization) }
    private var gpuTemp: Double? {
        let value = store.latest(for: .thermalGPU)?.value ?? 0
        return value > 0 ? value : nil
    }
    private var gpuPower: Double? {
        let value = store.latest(for: .powerGPU)?.value ?? 0
        return value > 0 ? value : nil
    }

    var body: some View {
        DashboardMetricCard(
            title: "GPU",
            systemImage: "cpu.fill",
            tint: tint,
            headline: { headlineRow },
            detail: { expandedDetail },
            footer: { tripletFooter },
        )
    }

    private var headlineRow: some View {
        HStack(alignment: .top, spacing: 20) {
            summary
                .frame(maxWidth: .infinity, alignment: .leading)
            trendChart
                .frame(width: 200, height: 110)
        }
    }

    // MARK: - Collapsed

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "%.1f", util))
                    .font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(value: util))
                    .animation(.smooth, value: util)
                Text("%")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text("Utilisation")
                .font(.caption)
                .foregroundStyle(.secondary)

            GeometryReader { proxy in
                Capsule().fill(tint.opacity(0.18))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(tint)
                            .frame(width: proxy.size.width * min(1, util / 100))
                    }
            }
            .frame(height: 6)
            .padding(.top, 4)

            HStack(spacing: 14) {
                if let gpuTemp {
                    metricChip(label: "temp", value: String(format: "%.0f°C", gpuTemp), color: .orange)
                }
                if let gpuPower {
                    metricChip(label: "power", value: String(format: "%.1f W", gpuPower), color: .yellow)
                }
            }
        }
    }

    private func metricChip(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
        }
    }

    private var trendChart: some View {
        MetricSparklineView(
            samples: store.history(for: .gpuUtilization),
            style: SparklineStyle(
                color: tint,
                fillOpacity: 0.18,
                lineWidth: 1.5,
                yMin: 0,
                yMax: 100,
            ),
        )
    }

    // MARK: - Expanded

    /// Tri-series overlay. Utilisation is on the canonical 0–100
    /// axis; thermal and power live on `nil` autoscale axes that
    /// the multi-series sparkline normalises into the same plot
    /// rectangle. The reader is the same metrics-store history,
    /// so no extra collection cost.
    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Telemetry")
                .font(.subheadline.weight(.semibold))

            // Three side-by-side mini-charts rather than a single
            // overlaid chart: the y-axes are incompatible (%, °C,
            // W) and overlaying them on shared axes would lie
            // about magnitude. Three small charts in a row gives
            // each metric its own scale while still letting the
            // user eyeball correlation across the same time axis.
            //
            // The chart row takes `maxHeight: .infinity` so it
            // grows to absorb the slack the shared card container
            // would otherwise dump as dead space between the
            // charts and the footer (the card is pinned to
            // `dashboardCardMinHeight` and any surplus lands in
            // the trailing Spacer). Letting the charts eat that
            // surplus keeps the Telemetry block visually anchored
            // to the footer instead of floating above a gap.
            HStack(spacing: 12) {
                miniSeries(
                    title: "Utilisation",
                    value: String(format: "%.0f%%", util),
                    color: tint,
                    samples: store.history(for: .gpuUtilization),
                    yMin: 0,
                    yMax: 100,
                )
                miniSeries(
                    title: "Thermal",
                    value: gpuTemp.map { String(format: "%.0f°C", $0) } ?? "—",
                    color: .orange,
                    samples: store.history(for: .thermalGPU),
                    yMin: 0,
                    yMax: nil,
                )
                miniSeries(
                    title: "Power",
                    value: gpuPower.map { String(format: "%.1f W", $0) } ?? "—",
                    color: .yellow,
                    samples: store.history(for: .powerGPU),
                    yMin: 0,
                    yMax: nil,
                )
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func miniSeries(title: String, value: String, color: Color, samples: [MetricSample], yMin: Double?, yMax: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(color)
            }
            MetricSparklineView(
                samples: samples,
                style: SparklineStyle(
                    color: color,
                    fillOpacity: 0.2,
                    lineWidth: 1.4,
                    yMin: yMin,
                    yMax: yMax,
                ),
            )
            .frame(minHeight: 80, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    private var tripletFooter: some View {
        HStack(spacing: 24) {
            footerSlot(title: "Utilisation", value: String(format: "%.0f%%", util), color: tint)
            footerSlot(title: "Temp", value: gpuTemp.map { String(format: "%.0f°C", $0) } ?? "—", color: .orange)
            footerSlot(title: "Power", value: gpuPower.map { String(format: "%.1f W", $0) } ?? "—", color: .yellow)
            Spacer()
        }
    }

    private func footerSlot(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(color)
        }
    }
}
