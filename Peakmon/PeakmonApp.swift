//
//  PeakmonApp.swift
//  Peakmon
//
//  Menu bar entry point. v0.1 wires up MetricsStore + MetricsScheduler
//  with a single CPUCollector so the label and dashboard render live
//  data.
//

import AppKit
import CoreGraphics
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
        Log.app.info("Peakmon runtime started")
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

        // Pick the text colour based on the *wallpaper* under the
        // menu bar rather than the system appearance, because the
        // menu bar is a translucent vibrancy layer that takes its
        // visible tone from the desktop image — a Light-Mode session
        // with a dark photo wallpaper still produces a dark menu bar
        // that would otherwise swallow black text, and vice versa.
        // Chart tints are emitted by `MenuBarBarChart` as non-template
        // pixels, so they keep their colour regardless of this choice.
        let usesLightText = WallpaperLuminance.shared.usesLightText()
        let textColour: Color = usesLightText ? .white : .black
        let dividerColour: Color = usesLightText ? .white.opacity(0.55) : .black.opacity(0.45)

        let composed = HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, segment in
                if index > 0 {
                    Rectangle()
                        .fill(dividerColour)
                        .frame(width: 0.5, height: 16)
                }
                MenuBarSegmentBlock(
                    segment: segment,
                    store: store,
                    cpuTint: cpuTint,
                    memoryTint: memoryTint,
                    diskTint: diskTint,
                    networkTint: networkTint,
                    gpuTint: gpuTint,
                )
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(textColour)
        .padding(.horizontal, 2)
        .frame(height: 22)
        .fixedSize()

        let renderer = ImageRenderer(content: composed)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage
        image?.isTemplate = false
        return image
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
    let usesLightText: Bool
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
        let usesLightText = WallpaperLuminance.shared.usesLightText()

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
            usesLightText: usesLightText,
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
    /// `MenuBarSegmentBlock.shortRate` actually displays:
    ///   - <1 KiB/s   -> bucket 0     ("  0K")
    ///   - <1000 KiB/s-> KiB integer  (" 12K")
    ///   - <10 MiB/s  -> 0.1 MiB      ("1.2M")
    ///   - <1000 MiB/s-> MiB integer  (" 12M")
    ///   - >=1000 MiB -> 0.1 GiB      ("1.2G")
    /// Anything inside the same display bucket maps to the same key
    /// and reuses the cached rasterised label.
    ///
    /// CRITICAL: this MUST use the *exact same* truncation as
    /// `shortRate` — `Int(x)` truncates toward zero (we mirror that
    /// with `.rounded(.down)` for non-negative input) and replicate
    /// the *exact* branch boundaries used in `shortRate`. Mixing
    /// rounding modes would let two `value`s that render to
    /// different strings collide on the cache key.
    private static func bucketRate(_ value: Double?) -> Double {
        guard let value, value > 0 else { return 0 }
        let kib = value / 1024
        if kib < 1 { return 0 }
        if kib < 1000 { return kib.rounded(.down) }
        let mib = kib / 1024
        if mib < 10 { return ((mib * 10).rounded(.down)) / 10 + 10_000 }
        if mib < 1000 { return mib.rounded(.down) + 1_000_000 }
        let gib = mib / 1024
        return ((gib * 10).rounded(.down)) / 10 + 100_000_000
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

/// Decides whether the menu bar label should render with light or
/// dark text by sampling the **wallpaper** under the menu bar strip.
///
/// macOS's menu bar is a translucent vibrancy layer, so its visible
/// tone is dictated by whatever sits beneath it. In a Light-Mode
/// session with a dark photo wallpaper the menu bar is dark; in a
/// Dark-Mode session with a bright wallpaper it is bright. Neither
/// `NSApp.effectiveAppearance` nor `NSColor.labelColor` reflects
/// that, so the label colour had to be derived from the actual
/// background. Reading the wallpaper file does not require any
/// entitlement (unlike screen capture), at the cost of being unable
/// to detect dynamic / live wallpapers or opaque windows behind the
/// menu bar.
///
/// The result is cached and re-derived only when the wallpaper URL
/// changes or `sampleInterval` seconds have elapsed, keeping the
/// per-tick signature work essentially free.
@MainActor
private final class WallpaperLuminance {
    static let shared = WallpaperLuminance()

    /// Luminance threshold above which the wallpaper is treated as
    /// "light" (so the label switches to dark text). 0.5 is the
    /// midpoint; anything brighter than mid-grey gets dark glyphs.
    private let luminanceThreshold: CGFloat = 0.5

    /// How often to re-check the wallpaper URL even when it appears
    /// unchanged. Catches the case where the user replaces the file
    /// in place (e.g. a dynamic wallpaper rotating its asset on a
    /// macOS schedule) without renaming it.
    private let sampleInterval: TimeInterval = 5.0

    private var cachedURL: URL?
    private var cachedUsesLightText = true
    private var lastSampledAt: Date = .distantPast
    private let log = Logger(subsystem: "com.crafcat7.Peakmon", category: "menubar.luminance")

    private init() {}

    /// Returns `true` if the menu bar text should be drawn in white
    /// (i.e. the wallpaper top strip is dark). Falls back to the
    /// previous decision when the wallpaper cannot be loaded.
    func usesLightText() -> Bool {
        let now = Date()
        guard let screen = NSScreen.main else { return cachedUsesLightText }
        let url = NSWorkspace.shared.desktopImageURL(for: screen)

        let urlChanged = url != cachedURL
        let stale = now.timeIntervalSince(lastSampledAt) >= sampleInterval
        guard urlChanged || stale else { return cachedUsesLightText }

        lastSampledAt = now
        cachedURL = url

        guard let url, let luminance = Self.topStripLuminance(of: url) else {
            // Fall back to system appearance when the wallpaper file
            // is missing, unreadable, or a non-image asset (e.g. an
            // .mov live wallpaper). This is strictly better than
            // randomly flipping the cached value.
            let match = NSApp.effectiveAppearance.bestMatch(
                from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight],
            )
            let isDark = match == .darkAqua || match == .vibrantDark
            cachedUsesLightText = isDark
            return cachedUsesLightText
        }

        cachedUsesLightText = luminance < luminanceThreshold
        return cachedUsesLightText
    }

    /// Loads `url` as a CGImage and averages the Rec. 601 luminance
    /// of its top ~3 % horizontal strip (the slice that visually
    /// underlies the menu bar). Returns `nil` if the URL cannot be
    /// decoded.
    private static func topStripLuminance(of url: URL) -> CGFloat? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        // Crop the top ~3 % of the image (matches the proportion of a
        // ~24 pt menu bar on a typical retina wallpaper roughly
        // 800 px tall in points). Clamp to at least 1 px so tiny
        // wallpapers still produce a sample.
        let stripHeight = max(height / 32, 1)
        guard let strip = cgImage.cropping(to: CGRect(
            x: 0, y: 0, width: width, height: stripHeight,
        )) else { return averageLuminance(of: cgImage) }

        return averageLuminance(of: strip)
    }

    /// Mean Rec. 601 luminance of `cgImage`, computed by box-filtering
    /// the whole image down to a single pixel via `CGContext`. This
    /// avoids walking every pixel of a multi-megapixel wallpaper on
    /// every sample.
    private static func averageLuminance(of cgImage: CGImage) -> CGFloat? {
        var pixel: [UInt8] = [0, 0, 0, 0]
        let colourSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colourSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let r = CGFloat(pixel[0]) / 255
        let g = CGFloat(pixel[1]) / 255
        let b = CGFloat(pixel[2]) / 255
        // Rec. 601 luma — green-heavy, matches the human eye's
        // perceived brightness and what AppKit uses for its own
        // contrast decisions on template imagery.
        return 0.299 * r + 0.587 * g + 0.114 * b
    }
}
