//
//  DashboardView.swift
//  Peakmon
//
//  v0.1 dashboard popover. Uses PeakmonUI card + Swift Charts sparkline
//  for a polished look that scales to future metrics.
//

import PeakmonCore
import PeakmonUI
import SwiftUI

struct DashboardView: View {
    @Environment(MetricsStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    @AppStorage("showCPUCard") private var showCPU = true
    @AppStorage("showMemoryCard") private var showMemory = true
    @AppStorage("showBatteryCard") private var showBattery = true
    @AppStorage("showDiskCard") private var showDisk = true
    @AppStorage("showNetworkCard") private var showNetwork = true

    @CardTintStorage(.cpu) var cpuTint
    @CardTintStorage(.memory) private var memoryTint
    @CardTintStorage(.battery) private var batteryTint
    @CardTintStorage(.disk) var diskTint
    @CardTintStorage(.network) var networkTint

    @ChartSeriesEnabled(.cpuTotal) var cpuTotalEnabled
    @ChartSeriesEnabled(.cpuUser) var cpuUserEnabled
    @ChartSeriesEnabled(.cpuSystem) var cpuSystemEnabled
    @ChartSeriesEnabled(.diskRead) var diskReadEnabled
    @ChartSeriesEnabled(.diskWrite) var diskWriteEnabled
    @ChartSeriesEnabled(.netIn) var netInEnabled
    @ChartSeriesEnabled(.netOut) var netOutEnabled

    private var total: Double { store.latest(for: .cpuTotal)?.value ?? 0 }
    private var user: Double { store.latest(for: .cpuUser)?.value ?? 0 }
    private var system: Double { store.latest(for: .cpuSystem)?.value ?? 0 }
    var history: [MetricSample] { store.history(for: .cpuTotal) }
    var cpuUserHistory: [MetricSample] { store.history(for: .cpuUser) }
    var cpuSystemHistory: [MetricSample] { store.history(for: .cpuSystem) }

    private var memoryUsed: Double { store.latest(for: .memoryUsed)?.value ?? 0 }
    private var memoryPressure: Double { store.latest(for: .memoryPressure)?.value ?? 0 }
    private var memoryHistory: [MetricSample] { store.history(for: .memoryPressure) }

    private var batterySample: MetricSample? { store.latest(for: .batteryLevel) }
    private var batteryPowerSource: BatteryPowerSource {
        guard let sample = store.latest(for: .batteryPowerSource) else { return .onBattery }
        return BatteryPowerSource(metricValue: sample.value)
    }

    private var diskUsed: Double { store.latest(for: .diskUsed)?.value ?? 0 }
    private var diskTotal: Double { store.latest(for: .diskTotal)?.value ?? 0 }
    private var diskRead: Double { store.latest(for: .diskReadRate)?.value ?? 0 }
    private var diskWrite: Double { store.latest(for: .diskWriteRate)?.value ?? 0 }
    var diskReadHistory: [MetricSample] { store.history(for: .diskReadRate) }
    var diskWriteHistory: [MetricSample] { store.history(for: .diskWriteRate) }

    private var netIn: Double { store.latest(for: .netInRate)?.value ?? 0 }
    private var netOut: Double { store.latest(for: .netOutRate)?.value ?? 0 }
    var netInHistory: [MetricSample] { store.history(for: .netInRate) }
    var netOutHistory: [MetricSample] { store.history(for: .netOutRate) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if showCPU { cpuCard }
            if showMemory { memoryCard }
            if showBattery, batterySample != nil { batteryCard }
            if showDisk { diskCard }
            if showNetwork { networkCard }

            if !anyCardVisible { emptyState }

            footer
        }
        .padding(14)
        .frame(width: 300)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: visibilityKey)
    }

    private var anyCardVisible: Bool {
        showCPU || showMemory || (showBattery && batterySample != nil) || showDisk || showNetwork
    }

    private var visibilityKey: String {
        "\(showCPU)\(showMemory)\(showBattery)\(showDisk)\(showNetwork)"
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "eye.slash")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("All cards hidden")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Enable cards in Settings › Display.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var cpuCard: some View {
        MetricCardView(
            title: "CPU",
            systemImage: "cpu",
            tint: cpuTint,
            accessory: {
                Text("\(total, specifier: "%.1f")%")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: total))
                    .animation(.smooth, value: total)
            },
            content: {
                VStack(alignment: .leading, spacing: 10) {
                    breakdown
                    MetricSparklineView(
                        series: cpuSparklineSeries,
                        yMin: 0,
                        yMax: 100,
                    )
                    .frame(height: 48)
                }
            },
        )
    }

    private var memoryCard: some View {
        MetricCardView(
            title: "Memory",
            systemImage: "memorychip",
            tint: memoryTint,
            accessory: {
                Text("\(memoryPressure, specifier: "%.0f")%")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: memoryPressure))
                    .animation(.smooth, value: memoryPressure)
            },
            content: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 18) {
                        MetricStatLabel(
                            label: "Used",
                            value: Self.formatBytes(memoryUsed),
                            tint: .purple,
                        )
                        Spacer()
                    }
                    MetricSparklineView(samples: memoryHistory, style: .memory)
                        .frame(height: 48)
                }
            },
        )
    }

    private var batteryCard: some View {
        let level = batterySample?.value ?? 0
        let source = batteryPowerSource
        return MetricCardView(
            title: "Battery",
            systemImage: batteryIconName(for: level, source: source),
            tint: batteryTint,
            accessory: {
                HStack(spacing: 6) {
                    BatteryStatusBadge(source: source, tint: batteryTint)
                    Text("\(level, specifier: "%.0f")%")
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText(value: level))
                        .animation(.smooth, value: level)
                }
            },
            content: {
                MetricSparklineView(
                    samples: store.history(for: .batteryLevel),
                    style: .battery,
                )
                .frame(height: 48)
            },
        )
        .overlay {
            if source == .charging {
                ChargingFlowOverlay(tint: batteryTint)
            }
        }
        .overlay(alignment: .topLeading) {
            if source == .acPlugged {
                StandbyIndicator(tint: batteryTint)
            }
        }
        .overlay {
            if source == .onBattery, level < 20 {
                LowBatteryPulse(level: level)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: source)
    }

    private var diskCard: some View {
        let usagePercent = diskTotal > 0 ? diskUsed / diskTotal * 100 : 0
        return MetricCardView(
            title: "Disk",
            systemImage: "internaldrive",
            tint: diskTint,
            accessory: {
                Text("\(usagePercent, specifier: "%.0f")%")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: usagePercent))
                    .animation(.smooth, value: usagePercent)
            },
            content: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 18) {
                        MetricStatLabel(
                            label: "Used",
                            value: Self.formatBytes(diskUsed),
                            tint: .cyan,
                        )
                        MetricStatLabel(
                            label: "Read",
                            value: Self.formatRate(diskRead),
                            tint: .blue,
                        )
                        MetricStatLabel(
                            label: "Write",
                            value: Self.formatRate(diskWrite),
                            tint: .orange,
                        )
                    }
                    MetricSparklineView(
                        series: diskSparklineSeries,
                        yMin: 0,
                        yMax: nil,
                    )
                    .frame(height: 48)
                }
            },
        )
    }

    private var networkCard: some View {
        MetricCardView(
            title: "Network",
            systemImage: "network",
            tint: networkTint,
            accessory: {
                Text(Self.formatRate(netIn + netOut))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
            },
            content: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 18) {
                        MetricStatLabel(
                            label: "Down",
                            value: Self.formatRate(netIn),
                            tint: .green,
                        )
                        MetricStatLabel(
                            label: "Up",
                            value: Self.formatRate(netOut),
                            tint: .pink,
                        )
                        Spacer()
                    }
                    MetricSparklineView(
                        series: networkSparklineSeries,
                        yMin: 0,
                        yMax: nil,
                    )
                    .frame(height: 48)
                }
            },
        )
    }

    private static func formatBytes(_ value: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(value))
    }

    private static func formatRate(_ bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .binary
        let value = formatter.string(fromByteCount: Int64(bytesPerSecond))
        return "\(value)/s"
    }

    private func batteryIconName(for percent: Double, source: BatteryPowerSource) -> String {
        // Charging or full-and-plugged states show the dedicated SF
        // symbols so the icon itself conveys power state at a glance.
        switch source {
        case .charging:
            return "battery.100percent.bolt"
        case .acPlugged where percent >= 99:
            return "battery.100percent.bolt"
        default:
            break
        }
        return switch percent {
        case ..<10: "battery.0percent"
        case ..<35: "battery.25percent"
        case ..<65: "battery.50percent"
        case ..<90: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "speedometer")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Peakmon")
                .font(.headline)
            Spacer()
            Text(history.isEmpty ? "Warming up…" : "Live")
                .font(.caption)
                .foregroundStyle(history.isEmpty ? Color.secondary : Color.green)
        }
    }

    private var breakdown: some View {
        HStack(alignment: .top, spacing: 18) {
            MetricStatLabel(
                label: "User",
                value: String(format: "%.1f%%", user),
                tint: .blue,
            )
            MetricStatLabel(
                label: "System",
                value: String(format: "%.1f%%", system),
                tint: .orange,
            )
            Spacer()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                openWindow(id: "settings")
                ActivationPolicyController.shared.activateRegular()
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Open Settings")

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    DashboardView()
        .environment(MetricsStore())
}
