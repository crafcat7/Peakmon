//
//  MetricSparklineView.swift
//  PeakmonUI
//
//  Swift Charts based sparkline rendering one or more rolling
//  windows of `MetricSample`s. Designed for embedding inside cards
//  / popovers — axes and chrome are intentionally suppressed.
//
//  Multi-series support lets dashboard cards overlay related
//  metrics on the same chart (e.g. CPU user + system, disk read +
//  write, network in + out). Each series carries its own colour.
//

import Charts
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
public struct SparklineSeries: Identifiable, Sendable {
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

/// Flattened `(series, sample)` row used internally by
/// `MetricSparklineView` so Swift Charts only walks one collection
/// per render pass. `Identifiable` because `Chart(_:)` needs a
/// stable id; the composite `"<seriesID>@<timestamp>"` form is both
/// unique and cheap to compute.
private struct SparklinePoint: Identifiable {
    let seriesID: String
    let sample: MetricSample
    let color: Color
    let fillOpacity: Double

    var id: String { "\(seriesID)@\(sample.timestamp.timeIntervalSinceReferenceDate)" }
}

/// Renders one or more rolling-window line charts in a single
/// frame. Empty inputs render an empty frame so the surrounding
/// layout doesn't jump when data first arrives.
public struct MetricSparklineView: View {
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
        Chart(flattenedPoints) { point in
            LineMark(
                x: .value("Time", point.sample.timestamp),
                y: .value("Value", point.sample.value),
                series: .value("Series", point.seriesID),
            )
            .interpolationMethod(.linear)
            .foregroundStyle(point.color)
            .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            AreaMark(
                x: .value("Time", point.sample.timestamp),
                y: .value("Value", point.sample.value),
                series: .value("Series", point.seriesID),
            )
            .interpolationMethod(.linear)
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        point.color.opacity(point.fillOpacity),
                        point.color.opacity(0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom,
                ),
            )
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: domainX)
        .chartYScale(domain: domainY)
        .chartPlotStyle { plot in
            plot.background(Color.clear)
        }
        .clipped()
    }

    /// One row per `(series, sample)` so Swift Charts can iterate a
    /// single flat collection instead of paying the diff cost of two
    /// nested `ForEach`es every body pass.
    private var flattenedPoints: [SparklinePoint] {
        var out: [SparklinePoint] = []
        out.reserveCapacity(series.reduce(0) { $0 + $1.samples.count })
        for line in series {
            for sample in line.samples {
                out.append(
                    SparklinePoint(
                        seriesID: line.id,
                        sample: sample,
                        color: line.color,
                        fillOpacity: line.fillOpacity,
                    ),
                )
            }
        }
        return out
    }

    private var domainX: ClosedRange<Date> {
        let timestamps = series.flatMap { $0.samples.map(\.timestamp) }
        guard let first = timestamps.min(),
              let last = timestamps.max(),
              first < last
        else {
            let now = Date.now
            return now.addingTimeInterval(-60) ... now
        }
        return first ... last
    }

    private var domainY: ClosedRange<Double> {
        let values = series.flatMap { $0.samples.map(\.value) }
        let lo = yMin ?? (values.min() ?? 0)
        let hiBase: Double
        if let configuredMax = yMax {
            hiBase = configuredMax
        } else {
            let observed = values.max() ?? 1
            hiBase = observed * 1.15
        }
        let hi = max(hiBase, lo + 1)
        return lo ... hi
    }
}
