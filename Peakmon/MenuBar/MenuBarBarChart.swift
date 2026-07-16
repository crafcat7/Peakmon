//
//  MenuBarBarChart.swift
//  Peakmon
//
//  A compact bar chart suitable for rendering inside the system menu
//  bar. When used standalone it can rasterise itself with a caller tint;
//  when embedded in `MenuBarLabel`, the outer label is rasterised as an
//  original image so the bars keep their metric colour.
//

import PeakmonCore
import PeakmonUI
import SwiftUI

struct MenuBarBarChart: View {
    let samples: [MetricSample]
    let tint: Color
    var barCount: Int = SegmentMetrics.miniChartBarCount
    /// Upper bound for normalisation. Pass `nil` to autoscale to the
    /// largest value in the visible window (with a small headroom).
    var maxValue: Double? = 100
    var size: CGSize = .init(width: 40, height: 16)
    /// When this chart is embedded in `MenuBarLabel`, the whole label
    /// is already rasterised by an outer `ImageRenderer`. Rendering
    /// the chart to its own image first doubles the SwiftUI render
    /// work, so callers can opt into native bars and let the outer
    /// renderer flatten everything once.
    var rasterize: Bool = true

    var body: some View {
        Group {
            if !rasterize {
                BarsView(
                    bars: normalisedBars(),
                    tint: tint,
                    size: size,
                )
            } else if let image = renderImage() {
                Image(nsImage: image)
                    .renderingMode(.original)
                    .interpolation(.high)
            } else {
                Color.clear.frame(width: size.width, height: size.height)
            }
        }
    }

    @MainActor
    private func renderImage() -> NSImage? {
        let bars = normalisedBars()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let key = MenuBarBarChartCacheKey(
            bars: bars,
            tintHex: tint.hexString,
            maxValue: maxValue,
            width: size.width,
            height: size.height,
            barCount: bars.count,
            scale: scale,
        )
        return MenuBarBarChartCache.shared.image(for: key) {
            let chart = BarsView(
                bars: bars,
                tint: tint,
                size: size,
            )
            let renderer = ImageRenderer(content: chart)
            renderer.scale = scale
            return renderer.nsImage
        }
    }

    private func normalisedBars() -> [Double] {
        let recent = samples.suffix(barCount).map(\.value)
        let ceiling: Double = if let fixed = maxValue {
            max(fixed, .leastNonzeroMagnitude)
        } else {
            // Autoscale with 15% headroom; never below 1 so an
            // all-zero history still produces a stable axis.
            max((recent.max() ?? 0) * 1.15, 1)
        }
        var values = recent.map { min(max($0 / ceiling, 0), 1) }
        if values.count < barCount {
            values = Array(repeating: 0, count: barCount - values.count) + values
        }
        return values
    }
}

private struct MenuBarBarChartCacheKey: Hashable {
    let bars: [Double]
    let tintHex: String
    let maxValue: Double?
    let width: CGFloat
    let height: CGFloat
    let barCount: Int
    let scale: CGFloat
}

@MainActor
private final class MenuBarBarChartCache {
    static let shared = MenuBarBarChartCache(capacity: 64)

    private let capacity: Int
    private var images: [MenuBarBarChartCacheKey: NSImage] = [:]
    private var order: [MenuBarBarChartCacheKey] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func image(
        for key: MenuBarBarChartCacheKey,
        render: () -> NSImage?,
    ) -> NSImage? {
        if let cached = images[key] {
            return cached
        }
        guard let image = render() else { return nil }
        images[key] = image
        order.append(key)
        if order.count > capacity, let oldest = order.first {
            images.removeValue(forKey: oldest)
            order.removeFirst()
        }
        return image
    }
}

private struct BarsView: View {
    let bars: [Double]
    let tint: Color
    let size: CGSize

    var body: some View {
        GeometryReader { proxy in
            let count = bars.count
            let spacing: CGFloat = 1
            let totalSpacing = spacing * CGFloat(max(count - 1, 0))
            let barWidth = max((proxy.size.width - totalSpacing) / CGFloat(count), 1)

            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, normalised in
                    RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                        .fill(tint)
                        .frame(
                            width: barWidth,
                            height: max(proxy.size.height * normalised, 1.5),
                        )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
        }
        .frame(width: size.width, height: size.height)
    }
}
