//
//  MetricSparklineView.swift
//  PeakmonUI
//
//  Compact rolling-window line chart for cards and popovers.
//
//  Originally implemented on top of Swift Charts (`Chart` +
//  `LineMark` + `AreaMark`). The Charts framework is convenient
//  for full-fledged plots — legends, axes, gestures — but for a
//  bare sparkline that just needs a stroked path and a faded
//  area under it, Charts is heavy: profiling the dashboard
//  showed `Chart`'s layout pass dominating main-thread CPU
//  every tick, easily ~30% wall-clock on a Pro core with six
//  cards visible at once. The Charts work is invisible (no
//  axes, no labels) yet still pays the full diff/layout cost
//  on every body pass.
//
//  This re-implementation draws the same visual in plain
//  SwiftUI `Canvas`: one `Path` for the line, one closed `Path`
//  filled with a `LinearGradient` for the area underneath, per
//  series. The Canvas's `GraphicsContext` writes directly into
//  the layer's display list with no per-point view diffing, so
//  redraws are cheap even with hundreds of samples and several
//  series stacked.
//
//  The public API (`init(samples:style:)`, `init(series:...)`,
//  `SparklineStyle`, `SparklineSeries`) is unchanged so every
//  card site keeps working without edits.
//

import PeakmonCore
import SwiftUI

/// Visual style for a sparkline. Tuned for small embedded use.
public struct SparklineStyle: Sendable {
    public var color: Color
    public var fillOpacity: Double
    public var lineWidth: CGFloat
    public var yMin: Double?
    public var yMax: Double?

    public init(
        color: Color = .accentColor,
        fillOpacity: Double = 0.18,
        lineWidth: CGFloat = 1.5,
        yMin: Double? = 0,
        yMax: Double? = 100,
    ) {
        self.color = color
        self.fillOpacity = fillOpacity
        self.lineWidth = lineWidth
        self.yMin = yMin
        self.yMax = yMax
    }

    public static let cpu = SparklineStyle(color: .blue)
    public static let memory = SparklineStyle(color: .green)
    public static let battery = SparklineStyle(color: .orange)
    /// Disk read/write rate — bytes/sec, so let the y-axis auto-scale.
    public static let disk = SparklineStyle(color: .cyan, yMin: 0, yMax: nil)
    /// Network in/out rate — bytes/sec, so let the y-axis auto-scale.
    public static let network = SparklineStyle(color: .pink, yMin: 0, yMax: nil)
}

/// A single named line on a multi-series sparkline.
public struct SparklineSeries: Identifiable, Sendable, Equatable {
    public let id: String
    public let samples: [MetricSample]
    public let color: Color
    public let fillOpacity: Double

    public init(
        id: String,
        samples: [MetricSample],
        color: Color,
        fillOpacity: Double = 0.14,
    ) {
        self.id = id
        self.samples = samples
        self.color = color
        self.fillOpacity = fillOpacity
    }
}

/// Renders one or more rolling-window line charts in a single
/// frame. Empty inputs render an empty frame so the surrounding
/// layout doesn't jump when data first arrives.
///
/// `Equatable` so SwiftUI can short-circuit body evaluation
/// when the `MetricsStore` ticks but the rolling window has
/// not actually changed for *this particular* sparkline yet —
/// in practice that happens often because each tick only
/// appends one sample per kind, and most cards subscribe to
/// only one or two kinds.
public struct MetricSparklineView: View, Equatable {
    private let series: [SparklineSeries]
    private let lineWidth: CGFloat
    private let yMin: Double?
    private let yMax: Double?

    /// Multi-series initialiser. The y-axis spans the union of every
    /// series, optionally clamped by `yMin`/`yMax`.
    public init(
        series: [SparklineSeries],
        lineWidth: CGFloat = 1.5,
        yMin: Double? = 0,
        yMax: Double? = nil,
    ) {
        self.series = series
        self.lineWidth = lineWidth
        self.yMin = yMin
        self.yMax = yMax
    }

    /// Single-series convenience initialiser preserving the original
    /// `SparklineStyle`-based API used throughout the dashboard.
    public init(samples: [MetricSample], style: SparklineStyle = .cpu) {
        self.init(
            series: [
                SparklineSeries(
                    id: "default",
                    samples: samples,
                    color: style.color,
                    fillOpacity: style.fillOpacity,
                ),
            ],
            lineWidth: style.lineWidth,
            yMin: style.yMin,
            yMax: style.yMax,
        )
    }

    public var body: some View {
        // A single Canvas hosts every series. Charts framework
        // had to spin up a full layout subgraph per series and
        // diff individual `LineMark` / `AreaMark` views; here we
        // emit two `Path`s per series straight into the display
        // list and pay zero diff cost.
        Canvas(rendersAsynchronously: false) { context, size in
            let (xDomain, yDomain) = resolvedDomains()
            // Treat zero-width / zero-height frames as nothing
            // to draw. Saves a divide-by-zero check later and
            // is what Charts does too.
            guard size.width > 0, size.height > 0 else { return }
            guard xDomain.upperBound > xDomain.lowerBound,
                  yDomain.upperBound > yDomain.lowerBound
            else { return }

            for line in series where line.samples.count >= 2 {
                drawSeries(
                    line,
                    in: &context,
                    size: size,
                    xDomain: xDomain,
                    yDomain: yDomain,
                )
            }
        }
        .clipped()
        // Note: previously wrapped in `.drawingGroup()` to push the
        // Canvas onto a Metal-backed offscreen layer. That helps
        // when the dashboard is stationary (a tick only rebuilds
        // one sparkline texture), but during scrolling the
        // offscreen layer has to be re-composited into the window's
        // backing store on every frame — `sample` showed
        // `RB::DisplayList::Layer::make_cgimage` accounting for
        // ~44 % of `render_items` time. Without `drawingGroup`,
        // SwiftUI batches every sparkline's Path into a single
        // CGDrawingLayer alongside its surrounding card, so
        // scrolling re-uses one cached layer instead of N.
    }

    // MARK: - Drawing

    /// Stroke the line and fill the area for a single series.
    /// We always draw the area first so the line sits crisply
    /// on top instead of being clipped at the bottom by the
    /// fill gradient's anti-alias edge.
    private func drawSeries(
        _ line: SparklineSeries,
        in context: inout GraphicsContext,
        size: CGSize,
        xDomain: ClosedRange<Date>,
        yDomain: ClosedRange<Double>,
    ) {
        let points = line.samples.map { sample -> CGPoint in
            projected(
                sample: sample,
                size: size,
                xDomain: xDomain,
                yDomain: yDomain,
            )
        }
        guard points.count >= 2 else { return }

        // Filled area: same outline as the line, plus two
        // anchor points along the baseline so the gradient
        // sweep clips cleanly to the row.
        var areaPath = Path()
        areaPath.move(to: CGPoint(x: points[0].x, y: size.height))
        for p in points {
            areaPath.addLine(to: p)
        }
        areaPath.addLine(to: CGPoint(x: points.last!.x, y: size.height))
        areaPath.closeSubpath()

        let gradient = Gradient(colors: [
            line.color.opacity(line.fillOpacity),
            line.color.opacity(0),
        ])
        context.fill(
            areaPath,
            with: .linearGradient(
                gradient,
                startPoint: CGPoint(x: size.width / 2, y: 0),
                endPoint: CGPoint(x: size.width / 2, y: size.height),
            ),
        )

        // Stroked line on top.
        var linePath = Path()
        linePath.move(to: points[0])
        for p in points.dropFirst() {
            linePath.addLine(to: p)
        }
        context.stroke(
            linePath,
            with: .color(line.color),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round),
        )
    }

    /// Map one `MetricSample` to the canvas's pixel space.
    /// We invert the y-axis (lower values go to higher pixel
    /// rows) so larger metrics render up, matching how every
    /// other dashboard renders these.
    private func projected(
        sample: MetricSample,
        size: CGSize,
        xDomain: ClosedRange<Date>,
        yDomain: ClosedRange<Double>,
    ) -> CGPoint {
        let xSpan = xDomain.upperBound.timeIntervalSince(xDomain.lowerBound)
        let xFrac = sample.timestamp.timeIntervalSince(xDomain.lowerBound) / max(xSpan, 0.001)
        let x = CGFloat(min(max(xFrac, 0), 1)) * size.width

        let ySpan = yDomain.upperBound - yDomain.lowerBound
        let yFrac = (sample.value - yDomain.lowerBound) / max(ySpan, 0.001)
        let y = size.height - CGFloat(min(max(yFrac, 0), 1)) * size.height

        return CGPoint(x: x, y: y)
    }

    // MARK: - Domain resolution

    /// Returns `(xDomain, yDomain)` exactly as the Charts
    /// version did: x spans the union of all sample
    /// timestamps; y spans `[yMin ?? observedMin,
    /// yMax ?? observedMax * 1.15]` with a guard so the
    /// range is always non-empty.
    private func resolvedDomains() -> (x: ClosedRange<Date>, y: ClosedRange<Double>) {
        var firstTS: Date?
        var lastTS: Date?
        var minV: Double = .greatestFiniteMagnitude
        var maxV: Double = -.greatestFiniteMagnitude

        // One pass over every sample of every series. This was
        // previously `flatMap` over `samples`; doing it inline
        // avoids the intermediate array allocation that Swift
        // can't always elide.
        for line in series {
            for s in line.samples {
                if firstTS == nil || s.timestamp < firstTS! { firstTS = s.timestamp }
                if lastTS == nil || s.timestamp > lastTS! { lastTS = s.timestamp }
                if s.value < minV { minV = s.value }
                if s.value > maxV { maxV = s.value }
            }
        }

        let xDomain: ClosedRange<Date> = {
            guard let lo = firstTS, let hi = lastTS, lo < hi else {
                let now = Date.now
                return now.addingTimeInterval(-60) ... now
            }
            return lo ... hi
        }()

        let yLo = yMin ?? (minV == .greatestFiniteMagnitude ? 0 : minV)
        let yHiBase: Double = {
            if let configured = yMax { return configured }
            if maxV == -.greatestFiniteMagnitude { return 1 }
            return maxV * 1.15
        }()
        let yHi = max(yHiBase, yLo + 1)
        return (xDomain, yLo ... yHi)
    }
}
