//
//  DashboardView.swift
//  Peakmon
//
//  v0.1 dashboard popover. Uses PeakmonUI card + Swift Charts sparkline
//  for a polished look that scales to future metrics.
//

import PeakmonCollectors
import PeakmonCore
import PeakmonUI
import SwiftUI

struct DashboardView: View {
    @Environment(MetricsStore.self) private var store
    @Environment(ProcessesStore.self) private var processesStore
    @Environment(\.openWindow) private var openWindow

    @CardVisibilityStorage(.cpu) private var showCPU
    @CardVisibilityStorage(.memory) private var showMemory
    @CardVisibilityStorage(.battery) private var showBattery
    @CardVisibilityStorage(.disk) private var showDisk
    @CardVisibilityStorage(.network) private var showNetwork
    @CardVisibilityStorage(.processes) private var showProcesses
    @CardVisibilityStorage(.gpu) private var showGPU
    @CardVisibilityStorage(.power) private var showPower
    @AppStorage("processesSortByMemory") private var processesSortByMemory = false

    @CardWidthStorage(.cpu) private var cpuWidth
    @CardWidthStorage(.memory) private var memoryWidth
    @CardWidthStorage(.battery) private var batteryWidth
    @CardWidthStorage(.disk) private var diskWidth
    @CardWidthStorage(.network) private var networkWidth
    @CardWidthStorage(.processes) private var processesWidth
    @CardWidthStorage(.gpu) private var gpuWidth
    @CardWidthStorage(.power) private var powerWidth

    @CardOrderStorage private var cardOrder: [CardTintSlot]

    @CardTintStorage(.cpu) var cpuTint
    @CardTintStorage(.memory) private var memoryTint
    @CardTintStorage(.battery) private var batteryTint
    @CardTintStorage(.disk) var diskTint
    @CardTintStorage(.network) var networkTint
    @CardTintStorage(.processes) var processesTint
    @CardTintStorage(.gpu) var gpuTint
    @CardTintStorage(.power) var powerTint

    @ChartSeriesEnabled(.cpuTotal) var cpuTotalEnabled
    @ChartSeriesEnabled(.cpuUser) var cpuUserEnabled
    @ChartSeriesEnabled(.cpuSystem) var cpuSystemEnabled
    @ChartSeriesEnabled(.diskRead) var diskReadEnabled
    @ChartSeriesEnabled(.diskWrite) var diskWriteEnabled
    @ChartSeriesEnabled(.netIn) var netInEnabled
    @ChartSeriesEnabled(.netOut) var netOutEnabled
    @ChartSeriesEnabled(.gpuDevice) var gpuDeviceEnabled
    @ChartSeriesEnabled(.gpuRenderer) var gpuRendererEnabled
    @ChartSeriesEnabled(.gpuTiler) var gpuTilerEnabled
    @ChartSeriesEnabled(.powerCPU) var powerCPUEnabled
    @ChartSeriesEnabled(.powerGPU) var powerGPUEnabled
    @ChartSeriesEnabled(.powerANE) var powerANEEnabled
    @ChartSeriesEnabled(.powerDRAM) var powerDRAMEnabled

    /// `true` only while the popover window is on-screen. Used to gate
    /// every `store.*` read so the popover stops subscribing to the
    /// `@Observable` `MetricsStore` once it is dismissed. Without this
    /// gate, `MenuBarExtra(.window)` keeps the dashboard view tree
    /// alive after the popover closes — every store ingest then forces
    /// a `body` recompute, which re-runs all sparklines, charts, and
    /// `Text` formatters, then commits a CALayer transaction whose
    /// `CGDrawingLayer.draw` rasterises every glyph again. The result
    /// is the ~20% steady-state CPU users observed after first opening
    /// the popover, even with the menu-bar label fully cached.
    @State private var isVisible = false

    /// Static GPU model + core count, populated once on first popover
    /// open from the IORegistry. Cached in `@State` so the IOKit query
    /// only runs once per app launch instead of on every body pass.
    /// Optional so the card stays usable on machines where the driver
    /// does not surface these fields (e.g. some VMs).
    @State private var gpuInfo: GPUDeviceInfo?

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

    private var gpuUtil: Double { store.latest(for: .gpuUtilization)?.value ?? 0 }
    var gpuUtilHistory: [MetricSample] { store.history(for: .gpuUtilization) }
    var gpuRendererHistory: [MetricSample] { store.history(for: .gpuRenderer) }
    var gpuTilerHistory: [MetricSample] { store.history(for: .gpuTiler) }

    private var powerCPU: Double { store.latest(for: .powerCPU)?.value ?? 0 }
    private var powerGPU: Double { store.latest(for: .powerGPU)?.value ?? 0 }
    private var powerANE: Double { store.latest(for: .powerANE)?.value ?? 0 }
    private var powerDRAM: Double { store.latest(for: .powerDRAM)?.value ?? 0 }
    private var powerPackage: Double { store.latest(for: .powerPackage)?.value ?? 0 }
    var powerCPUHistory: [MetricSample] { store.history(for: .powerCPU) }
    var powerGPUHistory: [MetricSample] { store.history(for: .powerGPU) }
    var powerANEHistory: [MetricSample] { store.history(for: .powerANE) }
    var powerDRAMHistory: [MetricSample] { store.history(for: .powerDRAM) }
    var powerPackageHistory: [MetricSample] { store.history(for: .powerPackage) }

    /// Popover width, in points. Bumped from 300 → 420 to give two
    /// half-width cards enough horizontal room to render without
    /// truncating their multi-stat headers; full-width cards still
    /// look balanced at this width because the new padding-to-content
    /// ratio (14:392) is close to the original (14:272).
    static let popoverWidth: CGFloat = 420

    var body: some View {
        Group {
            if isVisible {
                visibleContent
            } else {
                // Fixed-size placeholder so the popover keeps the same
                // window geometry while hidden, and — critically — does
                // *not* read any `store.*` property so the @Observable
                // store no longer triggers `body` recomputes here.
                Color.clear.frame(width: Self.popoverWidth, height: 1)
            }
        }
        .onAppear {
            isVisible = true
            if gpuInfo == nil { gpuInfo = GPUCollector.deviceInfo() }
        }
        .onDisappear { isVisible = false }
    }

    /// Real popover content. Lives in its own computed property so the
    /// outer `body` does not even touch `store.*` while the popover is
    /// hidden — the SwiftUI dependency tracker then has nothing to
    /// invalidate on each `MetricsStore.ingest` tick.
    private var visibleContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            ForEach(Array(DashboardLayout.rows(from: visibleCards).enumerated()), id: \.offset) { _, row in
                rowView(row)
            }

            if !anyCardVisible { emptyState }

            footer
        }
        .padding(14)
        .frame(width: Self.popoverWidth)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: visibilityKey)
    }

    /// Materialises the user's visibility + width + order
    /// preferences into the ordered card list `DashboardLayout`
    /// packs into rows. Order is driven by `CardOrderStorage` so
    /// the popover reflects whatever sequence the user dragged into
    /// place on the Settings › Display preview.
    private var visibleCards: [DashboardLayout.VisibleCard] {
        var cards: [DashboardLayout.VisibleCard] = []
        for slot in cardOrder where isVisible(slot) && hasData(slot) {
            cards.append(.init(slot: slot, width: width(of: slot), view: AnyView(cardView(for: slot))))
        }
        return cards
    }

    /// User's "show this card?" flag for the given slot. Centralises
    /// the per-slot `@CardVisibilityStorage` lookups so callers
    /// driven by `cardOrder` never have to mirror the slot ↔ flag
    /// mapping.
    private func isVisible(_ slot: CardTintSlot) -> Bool {
        switch slot {
        case .cpu: showCPU
        case .memory: showMemory
        case .battery: showBattery
        case .disk: showDisk
        case .network: showNetwork
        case .processes: showProcesses
        case .gpu: showGPU
        case .power: showPower
        }
    }

    /// User's persisted width preference for the given slot.
    private func width(of slot: CardTintSlot) -> CardWidth {
        switch slot {
        case .cpu: cpuWidth
        case .memory: memoryWidth
        case .battery: batteryWidth
        case .disk: diskWidth
        case .network: networkWidth
        case .processes: processesWidth
        case .gpu: gpuWidth
        case .power: powerWidth
        }
    }

    /// Extra per-slot gating beyond the user's visibility flag.
    /// Battery needs an actual battery sample. Power needs at least
    /// one telemetry tick from the IOReport collector — when the
    /// libIOReport dylib is missing or the user is on a host that
    /// does not expose the Energy Model group, the collector emits
    /// nothing and we hide the card entirely instead of showing
    /// "0.0 W" rows forever.
    private func hasData(_ slot: CardTintSlot) -> Bool {
        switch slot {
        case .battery: batterySample != nil
        case .power: store.latest(for: .powerPackage) != nil
        default: true
        }
    }

    /// Renders the concrete card body for a slot. This is the only
    /// place that dispatches a `CardTintSlot` to a card view; the
    /// caller (`visibleCards`) is now slot-agnostic.
    @ViewBuilder
    private func cardView(for slot: CardTintSlot) -> some View {
        switch slot {
        case .cpu: cpuCard
        case .memory: memoryCard
        case .battery: batteryCard
        case .disk: diskCard
        case .network: networkCard
        case .processes: processesCard
        case .gpu: gpuCard
        case .power: powerCard
        }
    }

    /// Renders a single laid-out row. Half-card pairs are emitted as
    /// an `HStack` with `.frame(maxWidth: .infinity)` on both children
    /// so SwiftUI divides the available space evenly; a lone card
    /// (full *or* half) gets `.frame(maxWidth: .infinity, alignment:
    /// .leading)` so it stretches the full row, preserving the v0.1
    /// look for users who never touch the new width preference.
    @ViewBuilder
    private func rowView(_ row: DashboardLayout.Row) -> some View {
        switch row {
        case let .single(card):
            if card.width == .half {
                HStack(spacing: 12) {
                    card.view
                        .environment(\.cardDensity, .half)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(maxWidth: .infinity)
                }
            } else {
                card.view
                    .environment(\.cardDensity, .full)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .pair(lhs, rhs):
            // Use a `Grid` for paired half-width cards so they
            // render at the same height and the same width:
            //
            //   * a `Grid` row aligns every cell to a shared
            //     baseline *and* sizes them to a shared height
            //     (the height of the tallest cell), which an
            //     ordinary HStack(alignment: .top) does not do —
            //     the latter only top-anchors otherwise
            //     intrinsically-sized children;
            //   * `.gridCellColumns(1)` paired with
            //     `.frame(maxWidth: .infinity)` on each cell makes
            //     the Grid divide the popover width evenly,
            //     matching the previous HStack behaviour.
            //
            // Critically, this affects only `.pair` rows. Single
            // full-width rows keep their existing
            // `.frame(maxWidth: .infinity, alignment: .leading)`
            // and their natural height, so the popover total
            // height is unchanged for users who never see a pair
            // row.
            Grid(horizontalSpacing: 12, verticalSpacing: 0) {
                GridRow {
                    lhs.view
                        .environment(\.cardDensity, .half)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading,
                        )
                    rhs.view
                        .environment(\.cardDensity, .half)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading,
                        )
                }
            }
            // Clamp the Grid's own height to the natural height of
            // its tallest cell so the equal-height behaviour does
            // not leak upward and inflate the popover's overall
            // height: SwiftUI's Grid would otherwise advertise an
            // unbounded ideal height because both cells declare
            // maxHeight: .infinity.
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var anyCardVisible: Bool {
        showCPU || showMemory || (showBattery && batterySample != nil)
            || showDisk || showNetwork || showProcesses || showGPU
            || (showPower && store.latest(for: .powerPackage) != nil)
    }

    private var visibilityKey: String {
        "\(showCPU)\(showMemory)\(showBattery)\(showDisk)\(showNetwork)\(showProcesses)\(showGPU)\(showPower)" +
            "|\(cpuWidth.rawValue)\(memoryWidth.rawValue)\(batteryWidth.rawValue)" +
            "\(diskWidth.rawValue)\(networkWidth.rawValue)\(processesWidth.rawValue)\(gpuWidth.rawValue)\(powerWidth.rawValue)" +
            "|" + cardOrder.map(\.rawValue).joined(separator: ",")
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
        DashboardCardTemplate(
            title: "CPU",
            systemImage: "cpu",
            tint: cpuTint,
            stats: [
                CardStat(label: "User", value: String(format: "%.1f%%", user), tint: .blue),
                CardStat(label: "System", value: String(format: "%.1f%%", system), tint: .orange),
            ],
            accessory: {
                Text("\(total, specifier: "%.1f")%")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: total))
                    .animation(.smooth, value: total)
            },
            chart: {
                MetricSparklineView(
                    series: cpuSparklineSeries,
                    yMin: 0,
                    yMax: 100,
                )
            },
        )
    }

    private var memoryCard: some View {
        DashboardCardTemplate(
            title: "Memory",
            systemImage: "memorychip",
            tint: memoryTint,
            stats: [
                CardStat(label: "Used", value: Self.formatBytes(memoryUsed), tint: .purple),
            ],
            accessory: {
                Text("\(memoryPressure, specifier: "%.0f")%")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: memoryPressure))
                    .animation(.smooth, value: memoryPressure)
            },
            chart: {
                MetricSparklineView(samples: memoryHistory, style: .memory)
            },
        )
    }

    private var batteryCard: some View {
        let level = batterySample?.value ?? 0
        let source = batteryPowerSource
        let isLow = source == .onBattery && level < 20
        let iconTint: Color = isLow ? .red : batteryTint
        let iconName = isLow
            ? "battery.0percent"
            : batteryIconName(for: level, source: source)
        return DashboardCardTemplate(
            title: "Battery",
            systemImage: iconName,
            tint: iconTint,
            stats: [
                CardStat(label: "Source", value: source.displayLabel, tint: batteryTint),
            ],
            accessory: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        BatteryStatusBadge(source: source, tint: batteryTint)
                        percentageText(level: level, source: source)
                    }
                    percentageText(level: level, source: source)
                }
            },
            chart: {
                MetricSparklineView(
                    samples: store.history(for: .batteryLevel),
                    style: .battery,
                )
            },
        )
        .overlay(alignment: .topLeading) {
            if let dotColor = batteryCornerDotColor(for: source) {
                BatteryCornerDot(color: dotColor)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: source)
    }

    /// Chooses the colour of the top-leading status dot on the
    /// battery card. Matches the amber/green convention Apple uses
    /// on its MagSafe and LED indicators: amber while charging,
    /// green once the battery is full (or charging has paused).
    /// Returns `nil` when on battery (no dot).
    private func batteryCornerDotColor(for source: BatteryPowerSource) -> Color? {
        switch source {
        case .charging: Color(red: 1.00, green: 0.65, blue: 0.10) // amber
        case .acPlugged: Color(red: 0.20, green: 0.80, blue: 0.30) // green
        case .onBattery: nil
        }
    }

    /// Shared accessory text for the battery card; extracted so both
    /// `ViewThatFits` branches render identical glyphs (otherwise the
    /// fits-check could pick the smaller branch even when the larger
    /// would fit, because differing fonts produce different intrinsic
    /// widths).
    private func percentageText(level: Double, source: BatteryPowerSource = .onBattery) -> some View {
        let isLow = source == .onBattery && level < 20
        return Text("\(level, specifier: "%.0f")%")
            .font(.title3.monospacedDigit().weight(.semibold))
            .foregroundStyle(isLow ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            .contentTransition(.numericText(value: level))
            .animation(.smooth, value: level)
    }

    private var diskCard: some View {
        let usagePercent = diskTotal > 0 ? diskUsed / diskTotal * 100 : 0
        return DashboardCardTemplate(
            title: "Disk",
            systemImage: "internaldrive",
            tint: diskTint,
            stats: [
                CardStat(label: "Used", value: Self.formatBytes(diskUsed), tint: .cyan),
                CardStat(label: "Read", value: Self.formatRate(diskRead), tint: .blue),
                CardStat(label: "Write", value: Self.formatRate(diskWrite), tint: .orange),
            ],
            accessory: {
                Text("\(usagePercent, specifier: "%.0f")%")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: usagePercent))
                    .animation(.smooth, value: usagePercent)
            },
            chart: {
                MetricSparklineView(
                    series: diskSparklineSeries,
                    yMin: 0,
                    yMax: nil,
                )
            },
        )
    }

    private var networkCard: some View {
        DashboardCardTemplate(
            title: "Network",
            systemImage: "network",
            tint: networkTint,
            stats: [
                CardStat(label: "Down", value: Self.formatRate(netIn), tint: .green),
                CardStat(label: "Up", value: Self.formatRate(netOut), tint: .pink),
            ],
            accessory: {
                let total = netIn + netOut
                Text(Self.formatRate(total))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: total))
                    .animation(.smooth, value: total)
            },
            chart: {
                MetricSparklineView(
                    series: networkSparklineSeries,
                    yMin: 0,
                    yMax: nil,
                )
            },
        )
    }

    private var gpuCard: some View {
        DashboardCardTemplate(
            title: "GPU",
            systemImage: "cpu.fill",
            tint: gpuTint,
            stats: {
                var s = [CardStat(label: "Model", value: gpuInfo?.model ?? "Unknown", tint: gpuTint)]
                if let cores = gpuInfo?.coreCount {
                    s.append(CardStat(label: "Cores", value: "\(cores)", tint: gpuTint))
                }
                return s
            }(),
            accessory: {
                Text("\(gpuUtil, specifier: "%.0f")%")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: gpuUtil))
                    .animation(.smooth, value: gpuUtil)
            },
            chart: {
                MetricSparklineView(
                    series: gpuSparklineSeries,
                    yMin: 0,
                    yMax: 100,
                )
            },
        )
    }

    /// Per-subsystem power draw, in watts. The headline `accessory`
    /// shows the package total (CPU + GPU + ANE + DRAM) and the
    /// stats row breaks out the three biggest contributors (CPU,
    /// GPU, ANE) so users can see at a glance which subsystem is
    /// currently dominating power use. The sparkline overlays
    /// however many of the four sub-rails the user has enabled in
    /// Settings › Display.
    private var powerCard: some View {
        DashboardCardTemplate(
            title: "Power",
            systemImage: "bolt.fill",
            tint: powerTint,
            stats: [
                CardStat(label: "CPU", value: Self.formatWatts(powerCPU), tint: .blue),
                CardStat(label: "GPU", value: Self.formatWatts(powerGPU), tint: .indigo),
                CardStat(label: "ANE", value: Self.formatWatts(powerANE), tint: .pink),
            ],
            accessory: {
                Text(Self.formatWatts(powerPackage))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: powerPackage))
                    .animation(.smooth, value: powerPackage)
            },
            chart: {
                MetricSparklineView(
                    series: powerSparklineSeries,
                    yMin: 0,
                    yMax: nil,
                )
            },
        )
    }

    /// Top-5 process card. Reads `processesStore.latestProcesses` which
    /// the ProcessCollector refreshes every 2 s on a background task.
    /// Sort order is controlled by `processesSortByMemory`; rows are
    /// trimmed to 5 here since the collector already limits to 10 to
    /// give the picker a little headroom for live re-sorting without
    /// dropping the user's currently-watched process.
    private var processesCard: some View {
        let processes = processesStore.latestProcesses
        let sorted: [ProcessSnapshot] = if processesSortByMemory {
            processes.sorted { $0.memoryBytes > $1.memoryBytes }
        } else {
            processes // collector already pre-sorts by CPU desc
        }
        let top = Array(sorted.prefix(5))
        let sortLabel = processesSortByMemory ? "by RAM" : "by CPU"

        return DashboardCardTemplate(
            title: "Top Processes",
            systemImage: "list.bullet.rectangle",
            tint: processesTint,
            accessory: {
                Text(sortLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            },
            body: {
                // Rows are sized so 5 caption-height entries (≈13pt
                // each) plus their inter-row spacing fill the
                // template's pinned 94pt content area: 5 × 13 + 4 ×
                // 7 = 93pt. Without the wider spacing the rows
                // huddle at the top of the card and the freeform
                // body leaves a visually distracting empty band
                // along the bottom.
                VStack(alignment: .leading, spacing: 7) {
                    if top.isEmpty {
                        Text("Collecting…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(top) { snapshot in
                            ProcessRow(
                                snapshot: snapshot,
                                showMemory: processesSortByMemory,
                            )
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
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

    /// Compact watt formatter shared by the Power card and its
    /// related menu-bar segment. Sub-watt readings (idle SoC) show
    /// one decimal; once draw exceeds 10 W the integer part already
    /// carries enough precision and the decimal just adds noise.
    static func formatWatts(_ watts: Double) -> String {
        let clamped = max(0, watts)
        if clamped < 10 {
            return String(format: "%.1fW", clamped)
        }
        return String(format: "%.0fW", clamped)
    }

    private func batteryIconName(for percent: Double, source: BatteryPowerSource) -> String {
        // Charging icons mirror the current charge level via the
        // `.bolt` variants so the symbol itself communicates both
        // "I am charging" and "how full I am". SF Symbols ships
        // bolt variants at 25/50/75/100 — clamp <25% to the 25
        // variant so the bolt stays present.
        if source == .charging {
            return switch percent {
            case ..<25: "battery.25percent.bolt"
            case ..<50: "battery.50percent.bolt"
            case ..<75: "battery.75percent.bolt"
            default: "battery.100percent.bolt"
            }
        }
        if source == .acPlugged, percent >= 99 {
            return "battery.100percent.bolt"
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
            // Mirror the visual language of the bundle's app icon —
            // a circular gauge face with tick dots and a needle — by
            // picking the matching SF Symbol instead of rasterising
            // the icon asset. This keeps the header monochrome,
            // tintable, and crisp at any size while still reading as
            // "Peakmon" at a glance.
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
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
