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
import PeakmonUI
import SwiftUI

@main
struct PeakmonApp: App {
    @State private var store = MetricsStore(historyLimit: 120)
    @State private var processesStore = ProcessesStore()
    @State private var runtime = MetricsRuntime()
    @Environment(\.openWindow) private var openWindow

    @AppStorage("silentLaunch") private var silentLaunch = false
    @AppStorage("samplingIntervalSeconds") private var samplingInterval: Double = 1.0
    @AppStorage("showProcessesCard") private var showProcesses = false

    var body: some Scene {
        MenuBarExtra {
            DashboardView()
                .environment(store)
                .environment(processesStore)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: runtime.started, initial: true) { _, started in
            if !started {
                runtime.start(
                    store: store,
                    processesStore: processesStore,
                    interval: samplingInterval,
                )
                runtime.processesEnabled = showProcesses
                bootstrap()
            }
        }
        .onChange(of: samplingInterval) { _, newValue in
            runtime.updateInterval(seconds: newValue)
        }
        .onChange(of: showProcesses, initial: false) { _, newValue in
            runtime.processesEnabled = newValue
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
    private var processTask: Task<Void, Never>?

    /// Toggled from SwiftUI to gate the process collector. When false,
    /// the background task still runs but skips the libproc walk and
    /// pushes an empty list into the store so the Top Processes card
    /// gracefully shows "—" instead of stale data.
    var processesEnabled = false {
        didSet {
            let value = processesEnabled
            let gate = processCollector
            Task { await gate.setEnabled(value) }
        }
    }

    /// Cadence at which the process collector polls libproc, in
    /// seconds. Kept slower than the host-metric scheduler because
    /// walking ~500 PIDs is ~50x more expensive than a single
    /// `host_statistics64` call. 2 s matches Activity Monitor's
    /// default refresh and is plenty for trend spotting.
    private static let processInterval: Duration = .seconds(2)
    private let processCollector = ProcessCollectorGate(collector: ProcessCollector(limit: 10))

    func start(
        store: MetricsStore,
        processesStore: ProcessesStore,
        interval: Double,
    ) {
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
                GPUCollector(),
            ],
            interval: Self.duration(seconds: interval),
        )
        self.scheduler = scheduler
        Task { await scheduler.start() }
        spawnProcessLoop(processesStore: processesStore)
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

    /// Long-running task that polls `ProcessCollector` on the slower
    /// fixed cadence. Cancellation happens implicitly when the
    /// runtime is deallocated; the task observes `Task.isCancelled`
    /// and returns cleanly.
    private func spawnProcessLoop(processesStore: ProcessesStore) {
        let gate = processCollector
        processTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                do {
                    if let snapshots = try await gate.collect() {
                        await MainActor.run {
                            processesStore.ingest(snapshots)
                        }
                    }
                } catch {
                    Log.collectors.error(
                        // swiftlint:disable:next line_length
                        "ProcessCollector failed: \(String(describing: error), privacy: .public)",
                    )
                }
                do {
                    try await Task.sleep(for: Self.processInterval)
                } catch {
                    return
                }
            }
        }
    }
}

/// Wrapper around `ProcessCollector` that gates expensive libproc
/// walks on a user-controllable enabled flag. When disabled, the
/// gate returns an empty list once (to clear stale data in the
/// store) and then `nil` to short-circuit subsequent polls without
/// any work. Re-enabling resets the gate so collection resumes
/// immediately on the next tick.
///
/// Implemented as an actor so the `enabled` / `didFlushAfterDisable`
/// state stays safe across the SwiftUI MainActor caller (toggle from
/// the settings page) and the detached background loop (long poll
/// every 2 s).
private actor ProcessCollectorGate {
    private let collector: ProcessCollector
    private var enabled = false
    private var didFlushAfterDisable = true

    init(collector: ProcessCollector) {
        self.collector = collector
    }

    func setEnabled(_ value: Bool) {
        if value == enabled { return }
        enabled = value
        // After flipping off, push one empty snapshot so the UI
        // forgets stale rows. After flipping on, the next collect()
        // will rebuild a baseline (first call returns []), then
        // produce real numbers on the call after that.
        didFlushAfterDisable = false
    }

    /// Returns:
    ///   - the latest snapshot list when collection is active
    ///   - `[]` exactly once after the collector was disabled, so the
    ///     consumer can clear stale data
    ///   - `nil` afterwards while still disabled, signalling "no
    ///     update needed"
    func collect() async throws -> [ProcessSnapshot]? {
        let isEnabled = enabled
        let needsFlush = !didFlushAfterDisable
        if needsFlush { didFlushAfterDisable = true }

        if !isEnabled {
            return needsFlush ? [] : nil
        }
        return try await collector.collect()
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
    @CardTintStorage(.gpu) private var gpuTint

    /// Cached rasterised label. Recomputed only when the source data
    /// actually changes, so the menu-bar refresh loop costs ~0 % CPU
    /// when metrics are stable. Boxed in a reference type so the body
    /// getter can mutate it without violating SwiftUI's pure-body rule.
    @State private var cache = MenuBarLabelCache()

    private var segments: [MenuBarSegment] {
        MenuBarComposition.decode(segmentsRaw)
    }

    var body: some View {
        let items = segments
        let signature = MenuBarLabelSignature.make(
            store: store,
            items: items,
            cpuTint: cpuTint,
            memoryTint: memoryTint,
            diskTint: diskTint,
            networkTint: networkTint,
            gpuTint: gpuTint,
        )
        let image = cache.image(for: signature) { render(items: items) }

        return Group {
            if let image {
                Image(nsImage: image)
                    .renderingMode(.original)
                    .interpolation(.high)
            } else {
                Text("Peakmon")
            }
        }
    }

    @MainActor
    private func render(items: [MenuBarSegment]) -> NSImage? {
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
        case .gpuPercent:
            let gpu = store.latest(for: .gpuUtilization)?.value ?? 0
            Text("GPU \(Int(gpu.rounded()))%")
        case .gpuGraph:
            HStack(spacing: 3) {
                Text("GPU")
                MenuBarBarChart(samples: store.history(for: .gpuUtilization), tint: gpuTint)
            }
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

/// Reference-typed cache for the rasterised menu-bar label. Kept in a
/// `class` so the SwiftUI body can read and update the cache in-place
/// without violating the "pure body" rule (`@State` value mutation
/// would trigger a runtime warning).
@MainActor
private final class MenuBarLabelCache {
    private var signature: MenuBarLabelSignature?
    private var image: NSImage?

    func image(
        for signature: MenuBarLabelSignature,
        render: () -> NSImage?,
    ) -> NSImage? {
        if let cached = self.signature, cached == signature, let image {
            return image
        }
        let newImage = render()
        self.signature = signature
        self.image = newImage
        return newImage
    }
}

/// Compact, value-equatable fingerprint of every input that affects the
/// rasterised menu-bar label. When two signatures match, the previously
/// cached `NSImage` can be reused without re-running the SwiftUI
/// renderer.
private struct MenuBarLabelSignature: Equatable {
    let segments: [MenuBarSegment]
    let isDark: Bool
    let tints: [String]      // [cpu, memory, disk, network, gpu] hex
    let latestValues: [Double]
    let historyHashes: [Int]

    @MainActor
    static func make(
        store: MetricsStore,
        items: [MenuBarSegment],
        cpuTint: Color,
        memoryTint: Color,
        diskTint: Color,
        networkTint: Color,
        gpuTint: Color,
    ) -> Self {
        let match = NSApp.effectiveAppearance.bestMatch(
            from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight],
        )
        let isDark = match == .darkAqua || match == .vibrantDark

        var latests: [Double] = []
        var historyHashes: [Int] = []
        for segment in items {
            switch segment {
            case .cpuPercent:
                latests.append(Self.round(store.latest(for: .cpuTotal)?.value))
            case .cpuGraph:
                historyHashes.append(Self.hashHistory(store.history(for: .cpuTotal), step: 1))
            case .memoryPercent:
                latests.append(Self.round(store.latest(for: .memoryPressure)?.value))
            case .memoryGraph:
                historyHashes.append(Self.hashHistory(store.history(for: .memoryPressure), step: 1))
            case .networkRate:
                latests.append(Self.bucketRate(store.latest(for: .netInRate)?.value))
                latests.append(Self.bucketRate(store.latest(for: .netOutRate)?.value))
            case .networkGraph:
                historyHashes.append(Self.hashRateHistory(store.history(for: .netInRate)))
                historyHashes.append(Self.hashRateHistory(store.history(for: .netOutRate)))
            case .diskRate:
                latests.append(Self.bucketRate(store.latest(for: .diskReadRate)?.value))
                latests.append(Self.bucketRate(store.latest(for: .diskWriteRate)?.value))
            case .diskGraph:
                historyHashes.append(Self.hashRateHistory(store.history(for: .diskReadRate)))
                historyHashes.append(Self.hashRateHistory(store.history(for: .diskWriteRate)))
            case .batteryPercent:
                latests.append(Self.round(store.latest(for: .batteryLevel)?.value))
                latests.append(store.latest(for: .batteryPowerSource)?.value ?? -1)
            case .gpuPercent:
                latests.append(Self.round(store.latest(for: .gpuUtilization)?.value))
            case .gpuGraph:
                historyHashes.append(Self.hashHistory(store.history(for: .gpuUtilization), step: 1))
            }
        }

        return MenuBarLabelSignature(
            segments: items,
            isDark: isDark,
            tints: [
                cpuTint.hexString,
                memoryTint.hexString,
                diskTint.hexString,
                networkTint.hexString,
                gpuTint.hexString,
            ],
            latestValues: latests,
            historyHashes: historyHashes,
        )
    }

    /// Quantises a metric value so 0.001-level jitter does not force a
    /// re-render. `step = 1` keeps integer percent precision.
    private static func round(_ value: Double?, _ step: Double = 1) -> Double {
        guard let value else { return -1 }
        return (value / step).rounded()
    }

    /// Quantises a byte/second rate to the granularity that
    /// `MenuBarLabel.shortRate` actually displays:
    ///   - <1 KiB/s  -> bucket 0  ("0K")
    ///   - <1 MiB/s  -> KiB integer ("Nk")
    ///   - <10 MiB/s -> 0.1 MiB ("X.YM")
    ///   - >=10 MiB/s-> MiB integer ("NM")
    /// Anything inside the same display bucket maps to the same key
    /// and reuses the cached rasterised label.
    ///
    /// CRITICAL: this MUST use the *exact same* truncation as
    /// `shortRate` — `Int(x)` truncates toward zero, whereas
    /// `x.rounded()` is half-to-even. Mixing the two would cause two
    /// different `value`s that render to *different* strings to map to
    /// the same cache key, then display the wrong rasterised label.
    /// E.g. `kib = 1023.6` renders as "1023K" but `(1023.6).rounded()
    /// == 1024.0` would collide with the bucket key for the `1.0M`
    /// branch. We therefore mirror `Int(...)` (`.rounded(.down)` for
    /// non-negative input) and replicate the *exact* branch boundaries
    /// of `shortRate`.
    private static func bucketRate(_ value: Double?) -> Double {
        guard let value, value > 0 else { return 0 }
        let kib = value / 1024
        if kib < 1 { return 0 }
        if kib < 1024 { return kib.rounded(.down) }
        let mib = kib / 1024
        if mib < 10 { return ((mib * 10).rounded(.down)) / 10 + 10_000 }
        return mib.rounded(.down) + 1_000_000
    }

    /// Hashes the visible window of a percent-style history (CPU/MEM)
    /// using only the value channel so identical bar layouts produce
    /// identical signatures regardless of how the timestamps advance.
    /// `step` controls the quantisation grid: `1` ≈ 1 percentage point,
    /// matching the resolution of a 16 px tall menu-bar bar chart.
    private static func hashHistory(_ history: [MetricSample], step: Double) -> Int {
        // 18 = MenuBarBarChart.barCount default. Hashing only the
        // visible window means off-screen jitter is ignored.
        let visible = history.suffix(18)
        var hasher = Hasher()
        hasher.combine(visible.count)
        for sample in visible {
            hasher.combine(Int((sample.value / step).rounded()))
        }
        return hasher.finalize()
    }

    /// Same as `hashHistory(_:step:)` but quantises through
    /// `bucketRate(_:)` so the rate-style chart's signature changes
    /// only when a displayed bar actually crosses a bucket boundary.
    private static func hashRateHistory(_ history: [MetricSample]) -> Int {
        let visible = history.suffix(18)
        var hasher = Hasher()
        hasher.combine(visible.count)
        for sample in visible {
            hasher.combine(Int(bucketRate(sample.value) * 10))
        }
        return hasher.finalize()
    }
}
