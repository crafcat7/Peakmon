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

    var body: some View {
        DashboardCardTemplate(
            title: "Memory",
            systemImage: "memorychip",
            tint: tint,
            stats: [
                CardStat(label: "Used", value: DashboardFormatting.bytes(used), tint: .purple),
            ],
            accessory: {
                Text("\(pressure, specifier: "%.0f")%")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: pressure))
                    .animation(.smooth, value: pressure)
            },
            chart: {
                MetricSparklineView(
                    samples: store.history(for: .memoryPressure),
                    style: .memory,
                )
            },
        )
    }
}
