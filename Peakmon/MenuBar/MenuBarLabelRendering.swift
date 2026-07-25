//
//  MenuBarLabelRendering.swift
//  Peakmon
//

import AppKit
import Combine
import CoreGraphics
import Foundation
import ImageIO
import PeakmonCore
import PeakmonUI
import SwiftUI

/// Menu bar title view that composes the selected `MenuBarSegment`
/// list (persisted via `@AppStorage`) into a `|`-separated label.
///
/// `MenuBarExtra` only honours `Text` and `Image` in its label, so the
/// composed SwiftUI view is rasterised through `ImageRenderer` and
/// emitted as a single `Image(nsImage:)` to guarantee both the bar
/// charts and the multi-segment layout reach the status bar intact.
private struct MenuBarLabel: View {
    let store: MetricsStore
    let runtime: MetricsRuntime

    @AppStorage(MenuBarComposition.storageKey)
    private var segmentsRaw = MenuBarComposition.encode(MenuBarComposition.defaultSegments)
    @CardTintStorage(.cpu) private var cpuTint
    @CardTintStorage(.memory) private var memoryTint
    @CardTintStorage(.disk) private var diskTint
    @CardTintStorage(.network) private var networkTint
    @CardTintStorage(.gpu) private var gpuTint
    @CardTintStorage(.power) private var powerTint

    /// Snapshot of the 6 tints that menu-bar graph segments may
    /// reference. Materialised lazily so the property wrappers above
    /// stay the single source of truth.
    private var tints: [CardTintSlot: Color] {
        [
            .cpu: cpuTint, .memory: memoryTint, .disk: diskTint,
            .network: networkTint, .gpu: gpuTint, .power: powerTint,
        ]
    }

    /// Cached rasterised label. Recomputed only when the source data
    /// actually changes, so the menu-bar refresh loop costs ~0 % CPU
    /// when metrics are stable. Boxed in a reference type so the body
    /// getter can mutate it without violating SwiftUI's pure-body rule.
    @State private var cache = MenuBarLabelCache()
    @ObservedObject private var foreground = StatusBarForeground.shared

    private var segments: [MenuBarSegment] {
        return MenuBarComposition.decode(segmentsRaw)
    }

    var body: some View {
        let items = segments
        let tints = self.tints
        let palette = foreground.palette()
        let signature = MenuBarLabelSignature.make(
            store: store,
            items: items,
            tints: tints,
            usesLightText: palette.usesLightText,
            appearanceGeneration: palette.generation,
        )
        let image = cache.image(for: signature) {
            render(items: items, tints: tints, palette: palette)
        }

        return Group {
            if let image {
                Image(nsImage: image)
                    .renderingMode(.original)
                    .interpolation(.high)
            } else {
                Text("Peakmon")
            }
        }
        .onChange(of: items, initial: true) { _, newValue in
            runtime.updateMenuBarSegments(newValue)
        }
    }

    @MainActor
    private func render(
        items: [MenuBarSegment],
        tints: [CardTintSlot: Color],
        palette: StatusBarPalette,
    ) -> NSImage? {
        guard !items.isEmpty else { return nil }

        let composed = HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, segment in
                if index > 0 {
                    Rectangle()
                        .fill(palette.divider)
                        .frame(width: 0.5, height: 16)
                }
                MenuBarSegmentBlock(
                    segment: segment,
                    store: store,
                    tints: tints,
                )
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(palette.foreground)
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
final class MenuBarLabelCache {
    private var renderedSignature: MenuBarLabelSignature?
    private var renderedAt: Date?
    private var image: NSImage?
    private let minimumMetricRenderInterval: TimeInterval = 1.0

    func image(
        for signature: MenuBarLabelSignature,
        force: Bool = false,
        render: () -> NSImage?,
    ) -> NSImage? {
        if !force, let cached = renderedSignature, cached == signature, let image {
            return image
        }
        let now = Date.now
        if !force,
           let cached = renderedSignature,
           let renderedAt,
           let image,
           cached.hasSameVisualConfiguration(as: signature),
           now.timeIntervalSince(renderedAt) < minimumMetricRenderInterval
        {
            return image
        }
        let newImage = render()
        renderedSignature = signature
        self.renderedAt = now
        image = newImage
        return newImage
    }
}

/// Compact, value-equatable fingerprint of every input that affects the
/// rasterised menu-bar label. When two signatures match, the previously
/// cached `NSImage` can be reused without re-running the SwiftUI
/// renderer.
struct MenuBarLabelSignature: Equatable {
    let segments: [MenuBarSegment]
    let usesLightText: Bool
    let appearanceGeneration: Int
    let tints: [String]      // [cpu, memory, disk, network, gpu, power] hex
    let latestValues: [Double]
    let historyHashes: [Int]

    func hasSameVisualConfiguration(as other: Self) -> Bool {
        segments == other.segments
            && usesLightText == other.usesLightText
            && appearanceGeneration == other.appearanceGeneration
            && tints == other.tints
    }

    @MainActor
    static func make(
        store: MetricsStore,
        items: [MenuBarSegment],
        tints: [CardTintSlot: Color],
        historyIssuesStore: HistoryIssuesStore? = nil,
        usesLightText: Bool,
        appearanceGeneration: Int,
    ) -> Self {
        var latests: [Double] = []
        var historyHashes: [Int] = []
        for segment in items {
            for input in segment.template.value.signatureInputs {
                switch input {
                case let .percent(kind):
                    latests.append(Self.round(store.latest(for: kind)?.value))
                case let .rate(kind):
                    latests.append(Self.bucketRate(store.latest(for: kind)?.value))
                case let .history(kind):
                    historyHashes.append(
                        Self.hashHistory(
                            store.historySuffix(for: kind, limit: SegmentMetrics.miniChartBarCount),
                            step: 1,
                        ),
                    )
                case let .historyWithFallback(primary, fallback):
                    let kind = (store.latest(for: primary)?.value ?? 0) > 0 ? primary : fallback
                    historyHashes.append(
                        Self.hashHistory(
                            store.historySuffix(for: kind, limit: SegmentMetrics.miniChartBarCount),
                            step: 1,
                        ),
                    )
                case let .rateHistory(kind):
                    historyHashes.append(
                        Self.hashRateHistory(
                            store.historySuffix(for: kind, limit: SegmentMetrics.miniChartBarCount),
                        ),
                    )
                case let .raw(kind):
                    latests.append(store.latest(for: kind)?.value ?? -1)
                case let .watts(kind):
                    latests.append(Self.bucketWatts(store.latest(for: kind)?.value))
                case let .wattsWithFallback(primary, fallback):
                    let kind = (store.latest(for: primary)?.value ?? 0) > 0 ? primary : fallback
                    latests.append(Self.bucketWatts(store.latest(for: kind)?.value))
                case .issueStatus:
                    latests.append(contentsOf: historyIssuesStore?.menuBarSignatureValues ?? [0, 0])
                }
            }
        }

        // Stable ordering by `CardTintSlot.allCases` so signature
        // equality compares apples to apples across calls. The 2
        // dashboard-only slots (battery/processes) are absent from
        // `tints` and serialise as empty strings, which is fine: their
        // absence is itself constant for menu-bar rendering.
        let tintHexes = CardTintSlot.allCases.map { tints[$0]?.hexString ?? "" }

        return MenuBarLabelSignature(
            segments: items,
            usesLightText: usesLightText,
            appearanceGeneration: appearanceGeneration,
            tints: tintHexes,
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

    /// Quantises a watts value to the granularity
    /// `MenuBarSegmentBlock.shortWatts` actually renders:
    ///   - <10W  -> 0.1W steps  ("9.9W")
    ///   - >=10W -> 1W steps    (" 12W", "999W")
    /// Mirrors `shortWatts`'s formatter rounding (`%.1f` → half-even,
    /// `%.0f` → half-even) closely enough that visible label
    /// boundaries also cross signature boundaries.
    private static func bucketWatts(_ value: Double?) -> Double {
        guard let value, value > 0 else { return 0 }
        if value < 10 { return (value * 10).rounded() / 10 }
        return value.rounded() + 10_000
    }

    /// Hashes the visible window of a percent-style history (CPU/MEM)
    /// using only the value channel so identical bar layouts produce
    /// identical signatures regardless of how the timestamps advance.
    /// `step` controls the quantisation grid: `1` ≈ 1 percentage point,
    /// matching the resolution of a 16 px tall menu-bar bar chart.
    private static func hashHistory(_ history: [MetricSample], step: Double) -> Int {
        var hasher = Hasher()
        hasher.combine(history.count)
        for sample in history {
            hasher.combine(Int((sample.value / step).rounded()))
        }
        return hasher.finalize()
    }

    /// Same as `hashHistory(_:step:)` but quantises through
    /// `bucketRate(_:)` so the rate-style chart's signature changes
    /// only when a displayed bar actually crosses a bucket boundary.
    private static func hashRateHistory(_ history: [MetricSample]) -> Int {
        var hasher = Hasher()
        hasher.combine(history.count)
        for sample in history {
            hasher.combine(Int(bucketRate(sample.value) * 10))
        }
        return hasher.finalize()
    }
}

struct StatusBarPalette {
    let foreground: Color
    let divider: Color
    let usesLightText: Bool
    let generation: Int
}

/// Decides whether the status bar label should render light or dark
/// text. The final label cannot be a template image because graph
/// segments need real colors, so scalar text is rasterized from the
/// current status-button tint with appearance and desktop-picture
/// fallbacks.
@MainActor
final class StatusBarForeground: ObservableObject {
    static let shared = StatusBarForeground()

    private static let desktopNotificationNames: [NSNotification.Name] = [
        NSNotification.Name("com.apple.desktop.changed"),
        NSNotification.Name("com.apple.DesktopPictureChanged"),
        NSNotification.Name("AppleDesktopPictureChangedNotification"),
    ]
    private static let wallpaperDarkThreshold = 0.56

    @Published private(set) var generation: Int = 0
    private var cachedPalette: StatusBarPalette?
    private var cachedGeneration: Int = -1
    private var cachedStatusAppearanceKey: String?
    private var desktopFingerprint: String = ""
    private var wallpaperDecision: WallpaperTextDecision?
    private var desktopPollTask: Task<Void, Never>?

    private init() {
        desktopFingerprint = Self.currentDesktopFingerprint()

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handleDesktopMayHaveChanged(force: true) }
        }

        for name in Self.desktopNotificationNames {
            DistributedNotificationCenter.default().addObserver(
                forName: name,
                object: nil,
                queue: .main,
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.handleDesktopMayHaveChanged(force: true) }
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handleDesktopMayHaveChanged(force: true) }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handleDesktopMayHaveChanged(force: true) }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handleDesktopMayHaveChanged(force: true) }
        }

        // The app appearance and desktop picture can settle a tick
        // after launch. Re-sample a few times so a dark menu bar does
        // not get stuck with the initial Light-Mode black fallback.
        scheduleStartupInvalidation(after: .milliseconds(0))
        scheduleStartupInvalidation(after: .milliseconds(150))
        scheduleStartupInvalidation(after: .milliseconds(600))

        desktopPollTask = Task { [weak self] in
            await self?.pollDesktopFingerprint()
        }
    }

    func palette(statusButton: NSButton? = nil) -> StatusBarPalette {
        let statusAppearanceKey = Self.statusAppearanceKey(statusButton)
        if let cachedPalette,
           cachedGeneration == generation,
           cachedStatusAppearanceKey == statusAppearanceKey
        {
            return cachedPalette
        }

        let usesLightText = computeUsesLightText(statusButton: statusButton)
        let foreground: Color = usesLightText ? .white : .black
        let dividerOpacity = usesLightText ? 0.55 : 0.45
        let palette = StatusBarPalette(
            foreground: foreground,
            divider: foreground.opacity(dividerOpacity),
            usesLightText: usesLightText,
            generation: generation,
        )
        cachedPalette = palette
        cachedGeneration = generation
        cachedStatusAppearanceKey = statusAppearanceKey
        return palette
    }

    private func pollDesktopFingerprint() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            refreshBackdrop()
        }
    }

    private func handleDesktopMayHaveChanged(force: Bool) {
        refreshBackdrop(forceInvalidate: force)
        scheduleStartupInvalidation(after: .milliseconds(150))
        scheduleStartupInvalidation(after: .milliseconds(600))
    }

    private func refreshBackdrop(forceInvalidate: Bool = false) {
        let nextFingerprint = Self.currentDesktopFingerprint()
        let desktopChanged = nextFingerprint != desktopFingerprint
        if desktopChanged {
            desktopFingerprint = nextFingerprint
        }
        if forceInvalidate || desktopChanged {
            wallpaperDecision = nil
        }
        if forceInvalidate || desktopChanged {
            invalidate()
        }
    }

    private func invalidate() {
        generation += 1
        cachedPalette = nil
        cachedStatusAppearanceKey = nil
    }

    private func scheduleStartupInvalidation(after delay: DispatchTimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.refreshBackdrop(forceInvalidate: true) }
        }
    }

    private func computeUsesLightText(statusButton: NSButton?) -> Bool {
        if let usesLightText = Self.statusIconUsesLightText(statusButton) {
            return usesLightText
        }
        if let usesLightText = Self.computeUsesLightText(button: statusButton)
            ?? Self.computeUsesLightText(appearance: NSApp.effectiveAppearance)
        {
            return usesLightText
        }
        if let wallpaperUsesLightText = computeWallpaperUsesLightText() {
            return wallpaperUsesLightText
        }
        return false
    }

    private func computeWallpaperUsesLightText() -> Bool? {
        let fingerprint = desktopFingerprint
        if let wallpaperDecision, wallpaperDecision.fingerprint == fingerprint {
            return wallpaperDecision.usesLightText
        }

        guard let usesLightText = Self.computeWallpaperUsesLightText() else {
            wallpaperDecision = nil
            return nil
        }
        wallpaperDecision = WallpaperTextDecision(
            fingerprint: fingerprint,
            usesLightText: usesLightText,
        )
        return usesLightText
    }

    private static func computeUsesLightText(button: NSButton?) -> Bool? {
        guard let button else { return nil }
        return computeUsesLightText(appearance: button.effectiveAppearance)
    }

    private static func computeUsesLightText(appearance: NSAppearance) -> Bool? {
        let match = appearance.bestMatch(
            from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight],
        )
        switch match {
        case .darkAqua, .vibrantDark:
            return true
        case .aqua, .vibrantLight:
            return false
        default:
            return nil
        }
    }

    private static func statusAppearanceKey(_ button: NSButton?) -> String {
        let appearance = button?.effectiveAppearance ?? NSApp.effectiveAppearance
        let match = appearance.bestMatch(
            from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight],
        )?.rawValue ?? "unknown"
        let screenName = button?.window?.screen?.localizedName
            ?? NSScreen.main?.localizedName
            ?? "no-screen"
        let tintKey = statusIconTintKey(button)
            ?? "no-tint"
        return "\(screenName)|\(match)|\(tintKey)"
    }

    private static func statusIconUsesLightText(_ button: NSButton?) -> Bool? {
        guard let button,
              let tint = button.contentTintColor,
              let luminance = relativeLuminance(of: tint, appearance: button.effectiveAppearance)
        else {
            return nil
        }
        return luminance >= 0.5
    }

    private static func statusIconTintKey(_ button: NSButton?) -> String? {
        guard let button,
              let tint = button.contentTintColor,
              let color = resolvedRGBColor(tint, appearance: button.effectiveAppearance)
        else {
            return nil
        }
        return String(
            format: "tint:%.3f,%.3f,%.3f,%.3f",
            Double(color.redComponent),
            Double(color.greenComponent),
            Double(color.blueComponent),
            Double(color.alphaComponent),
        )
    }

    private static func relativeLuminance(
        of color: NSColor,
        appearance: NSAppearance,
    ) -> Double? {
        guard let rgb = resolvedRGBColor(color, appearance: appearance) else { return nil }
        return 0.2126 * Double(rgb.redComponent)
            + 0.7152 * Double(rgb.greenComponent)
            + 0.0722 * Double(rgb.blueComponent)
    }

    private static func resolvedRGBColor(
        _ color: NSColor,
        appearance: NSAppearance,
    ) -> NSColor? {
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(NSColorSpace.deviceRGB)
        }
        return resolved
    }

    private static func computeWallpaperUsesLightText() -> Bool? {
        guard let screen = targetScreen(),
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let luminance = wallpaperTopStripLuminance(url: url)
        else {
            return nil
        }
        return luminance < wallpaperDarkThreshold
    }

    private static func currentDesktopFingerprint() -> String {
        guard let screen = targetScreen() else { return "no-screen" }

        let workspace = NSWorkspace.shared
        let url = workspace.desktopImageURL(for: screen)
        let path = url?.path ?? "no-url"
        let modifiedAt = url.flatMap { url in
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?
                .timeIntervalSince1970
        } ?? 0
        let options = workspace.desktopImageOptions(for: screen) ?? [:]
        let optionString = options
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: ";")

        return [
            screen.localizedName,
            "\(Int(screen.frame.width))x\(Int(screen.frame.height))",
            path,
            "\(modifiedAt)",
            optionString,
        ].joined(separator: "|")
    }

    private static func targetScreen() -> NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }

    private static func wallpaperTopStripLuminance(url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue

        return pixels.withUnsafeMutableBytes { buffer -> Double? in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo,
                  )
            else {
                return nil
            }

            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

            let pixelBytes = baseAddress.assumingMemoryBound(to: UInt8.self)
            let stripRows = max(1, height / 6)
            let startRow = max(0, height - stripRows)
            var luminanceSum = 0.0
            var sampledPixels = 0

            for row in startRow ..< height {
                let rowOffset = row * bytesPerRow
                for column in 0 ..< width {
                    let offset = rowOffset + column * bytesPerPixel
                    let alpha = Double(pixelBytes[offset + 3]) / 255.0
                    guard alpha > 0.01 else { continue }

                    let red = Double(pixelBytes[offset]) / 255.0
                    let green = Double(pixelBytes[offset + 1]) / 255.0
                    let blue = Double(pixelBytes[offset + 2]) / 255.0
                    luminanceSum += 0.2126 * red + 0.7152 * green + 0.0722 * blue
                    sampledPixels += 1
                }
            }

            guard sampledPixels > 0 else { return nil }
            return luminanceSum / Double(sampledPixels)
        }
    }
}

private struct WallpaperTextDecision {
    let fingerprint: String
    let usesLightText: Bool
}
