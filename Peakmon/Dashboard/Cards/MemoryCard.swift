//
//  MemoryCard.swift
//  Peakmon
//
//  Popover memory status card: current utilisation, used capacity,
//  and the kernel pressure band. Memory changes slowly enough that a
//  tiny sparkline adds less value than an explicit pressure state.
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

    /// Discrete kernel VM-pressure level (1 normal / 2 warning /
    /// 4 urgent / 8 critical). Nil while the collector has not yet
    /// shipped a sample (only on the very first tick after launch).
    private var pressureLevel: Int? {
        store.latest(for: .memoryPressureLevel).map { Int($0.value) }
    }

    /// Kernel pressure colour used by the status dot and label. The
    /// percentage remains primary text while normal and only
    /// adopts the warning colour once pressure escalates.
    private var pressureStateTint: Color {
        switch pressureLevel {
        case 2: .yellow
        case 4, 8: .red
        default: .green
        }
    }

    private var pressureValueTint: Color {
        pressureLevel == nil || pressureLevel == 1 ? .primary : pressureStateTint
    }

    private var pressureLabel: String {
        switch pressureLevel {
        case 2: "Warning"
        case 4: "Urgent"
        case 8: "Critical"
        default: "Normal"
        }
    }

    var body: some View {
        DashboardCardTemplate(
            title: "Memory",
            systemImage: "memorychip",
            tint: tint,
            accessory: {
                Text("\(pressure, specifier: "%.0f")%")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(pressureValueTint)
                    .contentTransition(.numericText(value: pressure))
                    .animation(.smooth, value: pressure)
            },
            body: {
                memoryStatus
            },
        )
        .animation(.smooth, value: pressureLevel ?? 1)
    }

    private var memoryStatus: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(DashboardFormatting.bytes(used))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint)
                Text("used")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 7) {
                Text("Pressure")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Circle()
                    .fill(pressureStateTint)
                    .frame(width: 8, height: 8)
                Text(pressureLabel)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(pressureValueTint)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
