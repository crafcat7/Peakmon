//
//  PeakmonApp.swift
//  Peakmon
//
//  Menu bar entry point. v0.1 wires up MetricsStore + MetricsScheduler
//  with a single CPUCollector so the label and dashboard render live
//  data.
//

import OSLog
import PeakmonCollectors
import PeakmonCore
import SwiftUI

@main
struct PeakmonApp: App {
    @State private var store = MetricsStore(historyLimit: 120)
    @State private var runtime = MetricsRuntime()
    @Environment(\.openWindow) private var openWindow

    @AppStorage("silentLaunch") private var silentLaunch = false
    @AppStorage("samplingIntervalSeconds") private var samplingInterval: Double = 1.0

    var body: some Scene {
        MenuBarExtra {
            DashboardView()
                .environment(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: runtime.started, initial: true) { _, started in
            if !started {
                runtime.start(store: store, interval: samplingInterval)
                bootstrap()
            }
        }
        .onChange(of: samplingInterval) { _, newValue in
            runtime.updateInterval(seconds: newValue)
        }

        Window("Peakmon Settings", id: "settings") {
            SettingsView()
                .environment(store)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 820, height: 560)
        .windowToolbarStyle(.unified)
    }

    private func bootstrap() {
        ActivationPolicyController.shared.install()
        ActivationPolicyController.shared.refresh()

        if !silentLaunch {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                openWindow(id: "settings")
                ActivationPolicyController.shared.activateRegular()
            }
        }
    }
}

/// Holds the long-running `MetricsScheduler` so SwiftUI can keep it
/// alive across re-renders.
@MainActor
@Observable
final class MetricsRuntime {
    private(set) var started = false
    private var scheduler: MetricsScheduler?

    func start(store: MetricsStore, interval: Double) {
        guard !started else { return }
        started = true
        let scheduler = MetricsScheduler(
            store: store,
            collectors: [
                CPUCollector(),
                MemoryCollector(),
                BatteryCollector(),
                DiskCollector(),
                NetworkCollector(),
            ],
            interval: Self.duration(seconds: interval),
        )
        self.scheduler = scheduler
        Task { await scheduler.start() }
        Log.app.info("Peakmon v0.1 runtime started")
    }

    /// Pushes a new sampling cadence into the running scheduler.
    /// Called from the SwiftUI scene whenever the user changes the
    /// `samplingIntervalSeconds` AppStorage value.
    func updateInterval(seconds: Double) {
        guard let scheduler else { return }
        let duration = Self.duration(seconds: seconds)
        Task { await scheduler.updateInterval(duration) }
    }

    private static func duration(seconds: Double) -> Duration {
        // `Duration.seconds(_:)` only accepts integers when used with
        // a `Double` literal needs `.milliseconds` to keep sub-second
        // precision (e.g. 0.5 s -> 500 ms).
        let millis = Int((seconds * 1000).rounded())
        return .milliseconds(max(50, millis))
    }
}

/// Menu bar title view that composes the selected `MenuBarSegment`
/// list (persisted via `@AppStorage`) into a `|`-separated label.
///
/// `MenuBarExtra` only honours `Text` and `Image` in its label, so the
/// composed SwiftUI view is rasterised through `ImageRenderer` and
/// emitted as a single `Image(nsImage:)` to guarantee both the bar
/// charts and the multi-segment layout reach the status bar intact.
private struct MenuBarLabel: View {
    let store: MetricsStore

    @AppStorage(MenuBarComposition.storageKey)
    private var segmentsRaw = MenuBarComposition.encode(MenuBarComposition.defaultSegments)
    @CardTintStorage(.cpu) private var cpuTint
    @CardTintStorage(.memory) private var memoryTint
    @CardTintStorage(.disk) private var diskTint
    @CardTintStorage(.network) private var networkTint

    /// Observing the store's latest tick forces this view to re-render
    /// every second; without it the rasterised image would freeze on
    /// whatever sample was current when the label first appeared.
    @State private var refreshTick = 0

    private var segments: [MenuBarSegment] {
        MenuBarComposition.decode(segmentsRaw)
    }

    var body: some View {
        Group {
            if let image = render() {
                Image(nsImage: image)
                    .renderingMode(.original)
                    .interpolation(.high)
            } else {
                Text("Peakmon")
            }
        }
        .task(id: refreshTick) {
            try? await Task.sleep(for: .seconds(1))
            refreshTick &+= 1
        }
    }

    @MainActor
    private func render() -> NSImage? {
        let items = segments
        guard !items.isEmpty else { return nil }

        // Pick the text colour based on the current system appearance
        // so the label keeps adequate contrast against both light and
        // dark menu bars. Chart tints are emitted by `MenuBarBarChart`
        // as a non-template `NSImage`, so they keep their colour
        // regardless of this choice.
        let match = NSApp.effectiveAppearance.bestMatch(
            from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight],
        )
        let isDark = match == .darkAqua || match == .vibrantDark
        let textColour: Color = isDark ? .white : .black
        let dividerColour: Color = isDark ? .white.opacity(0.55) : .black.opacity(0.45)

        let composed = HStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, segment in
                if index > 0 {
                    Text("|").foregroundStyle(dividerColour)
                }
                segmentView(segment)
            }
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(textColour)
        .padding(.horizontal, 2)
        .frame(height: 18)
        .fixedSize()

        let renderer = ImageRenderer(content: composed)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage
        image?.isTemplate = false
        return image
    }

    @ViewBuilder
    private func segmentView(_ segment: MenuBarSegment) -> some View {
        switch segment {
        case .cpuPercent:
            let cpu = store.latest(for: .cpuTotal)?.value ?? 0
            Text("CPU \(Int(cpu.rounded()))%")
        case .cpuGraph:
            HStack(spacing: 3) {
                Text("CPU")
                MenuBarBarChart(samples: store.history(for: .cpuTotal), tint: cpuTint)
            }
        case .memoryPercent:
            let mem = store.latest(for: .memoryPressure)?.value ?? 0
            Text("MEM \(Int(mem.rounded()))%")
        case .memoryGraph:
            HStack(spacing: 3) {
                Text("MEM")
                MenuBarBarChart(samples: store.history(for: .memoryPressure), tint: memoryTint)
            }
        case .networkRate:
            let down = store.latest(for: .netInRate)?.value ?? 0
            let up = store.latest(for: .netOutRate)?.value ?? 0
            Text("↓\(Self.shortRate(down)) ↑\(Self.shortRate(up))")
        case .networkGraph:
            HStack(spacing: 3) {
                Text("NET")
                MenuBarBarChart(
                    samples: Self.combinedHistory(store: store, kindA: .netInRate, kindB: .netOutRate),
                    tint: networkTint,
                    maxValue: nil,
                )
            }
        case .diskRate:
            let read = store.latest(for: .diskReadRate)?.value ?? 0
            let write = store.latest(for: .diskWriteRate)?.value ?? 0
            Text("R\(Self.shortRate(read)) W\(Self.shortRate(write))")
        case .diskGraph:
            HStack(spacing: 3) {
                Text("DISK")
                MenuBarBarChart(
                    samples: Self.combinedHistory(store: store, kindA: .diskReadRate, kindB: .diskWriteRate),
                    tint: diskTint,
                    maxValue: nil,
                )
            }
        case .batteryPercent:
            batteryPercentView
        }
    }

    @ViewBuilder
    private var batteryPercentView: some View {
        let pct = store.latest(for: .batteryLevel)?.value ?? 0
        let source = store.latest(for: .batteryPowerSource).map {
            BatteryPowerSource(metricValue: $0.value)
        } ?? .onBattery
        HStack(spacing: 2) {
            Text("BAT \(Int(pct.rounded()))%")
            if source == .charging {
                Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold))
            } else if source == .acPlugged {
                Image(systemName: "powerplug.fill").font(.system(size: 9, weight: .semibold))
            }
        }
    }

    private static func shortRate(_ bytesPerSecond: Double) -> String {
        let kib = bytesPerSecond / 1024
        if kib < 1 { return "0K" }
        if kib < 1024 { return "\(Int(kib))K" }
        let mib = kib / 1024
        if mib < 10 { return String(format: "%.1fM", mib) }
        return "\(Int(mib))M"
    }

    /// Combines two metric histories (e.g. disk read+write, network
    /// in+out) into a single series whose value is the sum of the
    /// paired samples — used to drive a unified "activity" bar chart.
    private static func combinedHistory(
        store: MetricsStore,
        kindA: MetricKind,
        kindB: MetricKind,
    ) -> [MetricSample] {
        let lhs = store.history(for: kindA)
        let rhs = store.history(for: kindB)
        let count = min(lhs.count, rhs.count)
        guard count > 0 else { return [] }
        return (0 ..< count).map { index in
            let left = lhs[lhs.count - count + index]
            let right = rhs[rhs.count - count + index]
            return MetricSample(
                kind: kindA,
                unit: left.unit,
                value: left.value + right.value,
                timestamp: left.timestamp,
            )
        }
    }
}
