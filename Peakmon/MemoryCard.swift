//
//  MemoryCard.swift
//  Peakmon
//
//  Dashboard memory card: used bytes stat + pressure accessory +
//  sparkline driven by the memory pressure history.
//

import PeakmonCore
import PeakmonUI
import SwiftUI

struct MemoryCard: View {
    @Environment(MetricsStore.self) private var store
    @Environment(\.cardSettings) private var cardSettings

    private var tint: Color { cardSettings.tint(.memory) }
    private var used: Double { store.value(for: .memoryUsed) }
    private var pressure: Double { store.value(for: .memoryPressure) }
    private var wired: Double { store.value(for: .memoryWired) }
    private var compressed: Double { store.value(for: .memoryCompressed) }
    private var swapUsed: Double? {
        store.latest(for: .memorySwapUsed)?.value
    }

    /// Discrete kernel VM-pressure level (1 normal / 2 warning /
    /// 4 urgent / 8 critical). Nil while the collector has not yet
    /// shipped a sample (only on the very first tick after launch).
    private var pressureLevel: Int? {
        store.latest(for: .memoryPressureLevel).map { Int($0.value) }
    }

    /// Colour the accessory percent should paint in, sourced from
    /// the kernel pressure band so it matches Activity Monitor's
    /// green/yellow/red strip instead of staying on the user's
    /// static accent while the kernel has escalated.
    private var pressureTint: Color {
        switch pressureLevel {
        case 2: .yellow
        case 4, 8: .red
        default: .primary
        }
    }

    /// Sparkline colour driven by the same pressure band as the
    /// accessory text, so the line in the card flips green → yellow
    /// → red in lockstep with the system pressure strip instead of
    /// staying on the static `SparklineStyle.memory` green while the
    /// kernel has already escalated. Normal pressure keeps the
    /// historical green palette so untriggered cards still look the
    /// same as before.
    private var sparklineStyle: SparklineStyle {
        let base = SparklineStyle.memory
        let color: Color = switch pressureLevel {
        case 2: .yellow
        case 4, 8: .red
        default: base.color
        }
        return SparklineStyle(
            color: color,
            fillOpacity: base.fillOpacity,
            lineWidth: base.lineWidth,
            yMin: base.yMin,
            yMax: base.yMax,
        )
    }

    /// Short label shown next to the percent when the kernel is
    /// past `normal`. Hidden during normal pressure so the card
    /// does not carry a permanent "Normal" sticker.
    private var pressureLabel: String? {
        switch pressureLevel {
        case 2: "Warning"
        case 4: "Urgent"
        case 8: "Critical"
        default: nil
        }
    }

    var body: some View {
        DashboardCardTemplate(
            title: "Memory",
            systemImage: "memorychip",
            tint: tint,
            stats: memoryStats(),
            accessory: {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(pressure, specifier: "%.0f")%")
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(pressureTint)
                        .contentTransition(.numericText(value: pressure))
                        .animation(.smooth, value: pressure)
                    if let pressureLabel {
                        Text(pressureLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(pressureTint)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(.smooth, value: pressureLevel ?? 1)
            },
            chart: {
                MetricSparklineView(
                    samples: store.history(for: .memoryPressure),
                    style: sparklineStyle,
                )
            },
        )
    }

    /// Stats row: Used (always), Wired, Compressed, and Swap (only
    /// when the kernel reports a non-zero figure — most desktops
    /// idle at 0 swap and an always-zero stat is just noise).
    /// Template caps to 2 in half-width mode, so order matters:
    /// Used first, then the two depth gauges, then swap.
    private func memoryStats() -> [CardStat] {
        var stats: [CardStat] = [
            CardStat(label: "Used", value: DashboardFormatting.bytes(used), tint: .purple),
            CardStat(label: "Wired", value: DashboardFormatting.bytes(wired), tint: tint),
            CardStat(
                label: "Compressed",
                value: DashboardFormatting.bytes(compressed),
                tint: tint,
            ),
        ]
        if let swapUsed, swapUsed > 0 {
            stats.append(CardStat(
                label: "Swap",
                value: DashboardFormatting.bytes(swapUsed),
                tint: swapUsed > 1_000_000_000 ? .orange : tint,
            ))
        }
        return stats
    }
}
