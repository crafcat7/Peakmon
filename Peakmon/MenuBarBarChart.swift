//
//  MenuBarBarChart.swift
//  Peakmon
//
//  A compact bar chart suitable for rendering inside the system menu
//  bar. Because `MenuBarExtra` flattens its label down to text + image
//  by way of `NSStatusItem`, we render the SwiftUI bar chart into an
//  `NSImage` via `ImageRenderer` and emit a non-template `Image` so
//  the bars keep their tint colour.
//

import PeakmonCore
import SwiftUI

struct MenuBarBarChart: View {
    let samples: [MetricSample]
    let tint: Color
    var barCount: Int = 18
    /// Upper bound for normalisation. Pass `nil` to autoscale to the
    /// largest value in the visible window (with a small headroom).
    var maxValue: Double? = 100
    var size: CGSize = .init(width: 40, height: 16)

    var body: some View {
        Group {
            if let image = renderImage() {
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
        let chart = BarsView(
            bars: normalisedBars(),
            tint: tint,
            size: size,
        )
        let renderer = ImageRenderer(content: chart)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
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
