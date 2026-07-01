//
//  HistorySurface.swift
//  Peakmon
//
//  Local diagnostics timeline for recent system history.
//

import PeakmonCore
import PeakmonUI
import SwiftUI

private struct HistoryRecorderEnvironmentKey: EnvironmentKey {
    static let defaultValue = HistoryRecorder()
}

extension EnvironmentValues {
    var historyRecorder: HistoryRecorder {
        get { self[HistoryRecorderEnvironmentKey.self] }
        set { self[HistoryRecorderEnvironmentKey.self] = newValue }
    }
}

struct HistorySurface: View {
    @Environment(\.historyRecorder) private var recorder
    @Environment(MetricsRuntime.self) private var runtime

    @State private var range: HistoryRange = .oneHour
    @State private var selectedDefinition: HistoryMetricDefinition = .cpu
    @State private var snapshot = HistorySnapshot.empty
    @State private var isRefreshing = false
    @State private var visibility = MainWindowVisibility.shared

    var body: some View {
        Group {
            if visibility.isMainWindowActive {
                activeContent
            } else {
                Color.clear
            }
        }
        .onDisappear {
            runtime.historyVisible = false
        }
        .onChange(of: visibility.isMainWindowActive, initial: true) { _, value in
            runtime.historyVisible = value
        }
        .task(id: refreshKey) {
            guard visibility.isMainWindowActive else { return }
            await refreshLoop(for: range)
        }
    }

    private var activeContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            HStack(alignment: .top, spacing: 16) {
                HistoryMetricSidebar(
                    metrics: snapshot.metrics,
                    selection: $selectedDefinition,
                )
                .frame(minWidth: 176, idealWidth: 196, maxWidth: 230)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HistoryMetricDetailPanel(
                            metric: snapshot.metric(for: selectedDefinition),
                            definition: selectedDefinition,
                            range: range,
                            capturedAt: snapshot.capturedAt,
                        )

                        HistoryEventPanel(
                            events: snapshot.events(for: selectedDefinition),
                            supportsAnomalies: !selectedDefinition.anomalyKinds.isEmpty,
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.bottom, 28)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var refreshKey: String {
        "\(range.rawValue)-\(visibility.isMainWindowActive)"
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.purple)
                .padding(7)
                .background(.purple.opacity(0.15), in: .rect(cornerRadius: 7))

            Text("History")
                .font(.title3.weight(.semibold))
                .lineLimit(1)

            Spacer()

            Picker("Range", selection: $range) {
                ForEach(HistoryRange.allCases, id: \.self) { item in
                    Text(item.displayName).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)

            Button {
                Task { await refreshOnce(for: range) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .disabled(isRefreshing)
            .help("Refresh")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.gray.opacity(0.18), lineWidth: 0.5)
        }
    }

    private func refreshLoop(for range: HistoryRange) async {
        await refreshOnce(for: range)
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: refreshInterval(for: range))
            } catch {
                return
            }
            await refreshOnce(for: range)
        }
    }

    private func refreshInterval(for range: HistoryRange) -> Duration {
        switch range {
        case .oneHour:
            .seconds(5)
        case .sixHours:
            .seconds(10)
        case .twentyFourHours:
            .seconds(60)
        }
    }

    private func refreshOnce(for range: HistoryRange) async {
        isRefreshing = true
        defer { isRefreshing = false }
        let next = await HistoryQueryService(recorder: recorder).snapshot(range: range)
        guard !Task.isCancelled, self.range == range else { return }
        snapshot = next
    }
}

private extension HistoryMetricSnapshot {
    var sparklineSeries: [HistoryTimeSparklineSeries] {
        visibleSeries.map {
            HistoryTimeSparklineSeries(
                id: $0.definition.kind.rawValue,
                label: $0.definition.label,
                buckets: $0.buckets,
                color: $0.definition.tint.color,
                fillOpacity: visibleSeries.count > 1 ? 0.08 : 0.14,
            )
        }
    }
}

private extension HistoryMetricTint {
    var color: Color {
        switch self {
        case .blue: .blue
        case .green: .green
        case .orange: .orange
        case .indigo: .indigo
        case .teal: .teal
        case .mint: .mint
        case .red: .red
        case .cyan: .cyan
        case .pink: .pink
        case .purple: .purple
        }
    }
}

private extension HistoryRange {
    var solidLineTolerance: TimeInterval {
        switch self {
        case .oneHour:
            45
        case .sixHours:
            3 * 60
        case .twentyFourHours:
            10 * 60
        }
    }

    var bridgeLineTolerance: TimeInterval {
        switch self {
        case .oneHour:
            5 * 60
        case .sixHours:
            20 * 60
        case .twentyFourHours:
            75 * 60
        }
    }

    var hoverSnapTolerance: TimeInterval {
        max(solidLineTolerance * 2, bucketInterval * 6)
    }
}

private struct HistoryMetricSidebar: View {
    let metrics: [HistoryMetricSnapshot]
    @Binding var selection: HistoryMetricDefinition

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(HistoryMetricDefinition.allCases, id: \.self) { definition in
                Button {
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        selection = definition
                    }
                } label: {
                    row(for: definition)
                }
                .buttonStyle(HistoryMetricSidebarButtonStyle(
                    tint: definition.tint.color,
                    isSelected: selection == definition,
                ))
            }
        }
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.gray.opacity(0.18), lineWidth: 0.5)
        }
    }

    private func row(for definition: HistoryMetricDefinition) -> some View {
        let metric = metrics.first { $0.definition == definition }
        let isSelected = selection == definition
        let hasData = metric != nil

        return HStack(spacing: 10) {
            Image(systemName: definition.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hasData ? definition.tint.color : .secondary)
                .frame(width: 24, height: 24)
                .background(
                    (hasData ? definition.tint.color : Color.gray).opacity(isSelected ? 0.18 : 0.10),
                    in: .rect(cornerRadius: 7),
                )

            Text(definition.title)
                .font(.subheadline.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(hasData ? .primary : .secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(sidebarValue(for: metric, definition: definition))
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(hasData ? .secondary : .tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func sidebarValue(for metric: HistoryMetricSnapshot?, definition: HistoryMetricDefinition) -> String {
        guard let metric else { return "--" }
        return formatMetricValue(metric.latest, unit: definition.unit)
    }
}

private struct HistoryMetricSidebarButtonStyle: ButtonStyle {
    let tint: Color
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(backgroundColor(isPressed: configuration.isPressed), in: .rect(cornerRadius: 10))
            .overlay {
                if isSelected || configuration.isPressed {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(tint.opacity(configuration.isPressed ? 0.45 : 0.30), lineWidth: 0.7)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return tint.opacity(isSelected ? 0.20 : 0.12)
        }
        return isSelected ? tint.opacity(0.13) : Color.clear
    }
}

private struct HistoryMetricDetailPanel: View {
    let metric: HistoryMetricSnapshot?
    let definition: HistoryMetricDefinition
    let range: HistoryRange
    let capturedAt: Date

    private var visibleSeries: [HistoryMetricSeriesSnapshot] {
        metric?.visibleSeries ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: definition.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(definition.tint.color)
                    .frame(width: 34, height: 34)
                    .background(definition.tint.color.opacity(0.15), in: .rect(cornerRadius: 8))

                Text(definition.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)

                Spacer()
            }

            if let metric {
                HistoryTimeSparklineView(
                    series: metric.sparklineSeries,
                    range: range,
                    capturedAt: capturedAt,
                    animationScope: definition.rawValue,
                    mode: definition.chartMode,
                    unit: definition.unit,
                    lineWidth: 2,
                    yMin: 0,
                    yMax: definition.yMax,
                    thresholdBands: definition.thresholdBands,
                )
                .frame(minHeight: 300)

                HistorySamplingDiagnosticsStrip(
                    diagnostics: metric.diagnostics(in: range, at: capturedAt),
                )

                HistorySeriesStatsGrid(series: visibleSeries)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("No data in this range")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 342, alignment: .center)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.gray.opacity(0.18), lineWidth: 0.5)
        }
    }
}

private struct HistorySamplingDiagnosticsStrip: View {
    let diagnostics: HistoryMetricDiagnostics

    var body: some View {
        HStack(spacing: 8) {
            chip(label: "Coverage", value: coverageText)
            chip(label: "Samples", value: "\(diagnostics.sampleCount)")
            chip(label: "Max gap", value: durationText(diagnostics.longestGap))
            chip(label: "Last seen", value: lastSeenText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var coverageText: String {
        "\(Int((diagnostics.coverageFraction * 100).rounded()))%"
    }

    private var lastSeenText: String {
        guard let latestSampleAge = diagnostics.latestSampleAge else { return "--" }
        if latestSampleAge < 3 {
            return "Live"
        }
        return "\(durationText(latestSampleAge)) ago"
    }

    private func chip(label: String, value: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.gray.opacity(0.075), in: .rect(cornerRadius: 7))
    }
}

private struct HistorySeriesStatsGrid: View {
    let series: [HistoryMetricSeriesSnapshot]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(series) { item in
                HStack(spacing: 12) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(item.definition.tint.color)
                            .frame(width: 8, height: 8)
                        Text(item.definition.label)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    .frame(width: 110, alignment: .leading)

                    stat("Latest", item.latest, unit: item.definition.unit)
                    stat("Avg", item.average, unit: item.definition.unit)
                    stat("Peak", item.peak, unit: item.definition.unit)
                }
                .padding(.vertical, 8)

                if item.id != series.last!.id {
                    Divider().opacity(0.45)
                }
            }
        }
    }

    private func stat(_ label: String, _ value: Double?, unit: MetricUnit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(formatMetricValue(value, unit: unit))
                .font(.callout.monospacedDigit().weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HistoryTimeSparklineSeries: Identifiable {
    let id: String
    let label: String
    let buckets: [MetricHistoryBucket]
    let color: Color
    let fillOpacity: Double
}

private struct HistoryChartHoverItem: Identifiable {
    let id: String
    let label: String
    let value: Double
    let peakValue: Double?
    let unit: MetricUnit
    let color: Color
    let point: CGPoint
}

private struct HistoryChartHoverSnapshot {
    let x: CGFloat
    let date: Date
    let items: [HistoryChartHoverItem]
}

private struct HistoryChartHoverOverlay: View {
    let snapshot: HistoryChartHoverSnapshot
    let plotRect: CGRect

    private let tooltipWidth: CGFloat = 210

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: snapshot.x, y: plotRect.minY))
                path.addLine(to: CGPoint(x: snapshot.x, y: plotRect.maxY))
            }
            .stroke(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 0.8, dash: [4, 4]))

            ForEach(snapshot.items) { item in
                Circle()
                    .fill(item.color)
                    .frame(width: 7, height: 7)
                    .overlay {
                        Circle()
                            .stroke(.background, lineWidth: 2)
                    }
                    .position(item.point)
            }

            tooltip
                .frame(width: tooltipWidth, alignment: .leading)
                .position(x: tooltipX, y: plotRect.minY + 46)
        }
        .allowsHitTesting(false)
    }

    private var tooltip: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(snapshot.date.formatted(date: .omitted, time: .standard))
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            ForEach(snapshot.items) { item in
                HStack(spacing: 8) {
                    Circle()
                        .fill(item.color)
                        .frame(width: 7, height: 7)
                    Text(item.label)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    tooltipValue(for: item)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .rect(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.gray.opacity(0.24), lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private func tooltipValue(for item: HistoryChartHoverItem) -> some View {
        if let peakValue = item.peakValue {
            VStack(alignment: .trailing, spacing: 1) {
                Text("Avg \(formatMetricValue(item.value, unit: item.unit))")
                    .foregroundStyle(.secondary)
                Text("Peak \(formatMetricValue(peakValue, unit: item.unit))")
                    .foregroundStyle(item.color)
            }
            .font(.caption2.monospacedDigit().weight(.medium))
            .lineLimit(1)
        } else {
            Text(formatMetricValue(item.value, unit: item.unit))
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var tooltipX: CGFloat {
        let lower = plotRect.minX + tooltipWidth * 0.5
        let upper = max(lower, plotRect.maxX - tooltipWidth * 0.5)
        return min(max(snapshot.x + tooltipWidth * 0.5 + 12, lower), upper)
    }
}

private struct HistoryTimeSparklineView: View {
    let series: [HistoryTimeSparklineSeries]
    let range: HistoryRange
    let capturedAt: Date
    let animationScope: String
    let mode: HistoryChartMode
    let unit: MetricUnit
    let lineWidth: CGFloat
    let yMin: Double?
    let yMax: Double?
    let thresholdBands: [HistoryThresholdBand]

    @State private var drawProgress = 0.0
    @State private var hoverLocation: CGPoint?

    private var peakMarkerMinimumDelta: Double {
        switch unit {
        case .percent, .ratio:
            1
        case .celsius:
            0.5
        case .watts, .bytes, .bytesPerSecond, .count, .rpm:
            0.001
        }
    }

    var body: some View {
        let yDomain = resolvedYDomain()
        let xDomain = resolvedXDomain()
        let animationKey = "\(range.rawValue)-\(mode.rawValue)"

        ZStack {
            Canvas(rendersAsynchronously: true) { context, size in
                guard size.width > 0, size.height > 0 else { return }
                guard yDomain.upperBound > yDomain.lowerBound else { return }

                let plotRect = plotRect(for: size)
                drawCoordinatePlane(
                    in: &context,
                    plotRect: plotRect,
                    xDomain: xDomain,
                    yDomain: yDomain,
                )

                drawGapRegions(
                    buckets: visibleBucketsForAnySeries(xDomain: xDomain),
                    in: &context,
                    plotRect: plotRect,
                    xDomain: xDomain,
                )

                for (index, line) in series.enumerated() {
                    drawSeries(
                        line,
                        index: index,
                        count: max(series.count, 1),
                        in: &context,
                        plotRect: plotRect,
                        xDomain: xDomain,
                        yDomain: yDomain,
                    )
                }

                drawAxes(
                    in: &context,
                    plotRect: plotRect,
                    xDomain: xDomain,
                    yDomain: yDomain,
                )
            }
            .clipped()

            GeometryReader { proxy in
                if let hover = hoverSnapshot(
                    location: hoverLocation,
                    size: proxy.size,
                    xDomain: xDomain,
                    yDomain: yDomain,
                ) {
                    HistoryChartHoverOverlay(snapshot: hover, plotRect: plotRect(for: proxy.size))
                }
            }
        }
        .contentShape(.rect)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hoverLocation = location
            case .ended:
                hoverLocation = nil
            }
        }
        .onAppear {
            restartAnimation()
        }
        .onChange(of: animationKey) { _, _ in
            restartAnimation()
        }
        .onChange(of: animationScope) { _, _ in
            drawProgress = 1
        }
    }

    private func drawSeries(
        _ line: HistoryTimeSparklineSeries,
        index: Int,
        count: Int,
        in context: inout GraphicsContext,
        plotRect: CGRect,
        xDomain: ClosedRange<Date>,
        yDomain: ClosedRange<Double>,
    ) {
        let orderedBuckets = visibleBuckets(for: line, xDomain: xDomain)

        switch mode {
        case .line:
            drawLineSeries(line, buckets: orderedBuckets, in: &context, plotRect: plotRect, xDomain: xDomain, yDomain: yDomain)
            drawThresholdPeakMarkers(
                line,
                buckets: orderedBuckets,
                in: &context,
                plotRect: plotRect,
                xDomain: xDomain,
                yDomain: yDomain,
            )
        case .bars:
            drawBarSeries(
                line,
                buckets: orderedBuckets,
                index: index,
                count: count,
                in: &context,
                plotRect: plotRect,
                xDomain: xDomain,
                yDomain: yDomain,
            )
        }
    }

    private func visibleBuckets(
        for line: HistoryTimeSparklineSeries,
        xDomain: ClosedRange<Date>,
    ) -> [MetricHistoryBucket] {
        line.buckets
            .filter { $0.avg.isFinite && bucketOverlaps($0, xDomain: xDomain) }
            .sorted { $0.startDate < $1.startDate }
    }

    private func visibleBucketsForAnySeries(
        xDomain: ClosedRange<Date>,
    ) -> [MetricHistoryBucket] {
        series
            .flatMap { visibleBuckets(for: $0, xDomain: xDomain) }
            .sorted { $0.startDate < $1.startDate }
    }

    private func bucketOverlaps(
        _ bucket: MetricHistoryBucket,
        xDomain: ClosedRange<Date>,
    ) -> Bool {
        let end = bucket.startDate.addingTimeInterval(bucket.resolution)
        return end >= xDomain.lowerBound && bucket.startDate <= xDomain.upperBound
    }

    private func drawGapRegions(
        buckets orderedBuckets: [MetricHistoryBucket],
        in context: inout GraphicsContext,
        plotRect: CGRect,
        xDomain: ClosedRange<Date>,
    ) {
        guard orderedBuckets.count >= 2 else { return }

        var previous = orderedBuckets[0]
        for bucket in orderedBuckets.dropFirst() {
            let tolerance = bridgeContinuityTolerance(previous: previous, current: bucket)
            if bucket.startDate.timeIntervalSince(previous.startDate) > tolerance {
                let start = max(
                    previous.startDate.addingTimeInterval(previous.resolution),
                    xDomain.lowerBound,
                )
                let end = min(bucket.startDate, xDomain.upperBound)
                drawGapRegion(from: start, to: end, in: &context, plotRect: plotRect, xDomain: xDomain)
            }
            previous = bucket
        }
    }

    private func drawGapRegion(
        from start: Date,
        to end: Date,
        in context: inout GraphicsContext,
        plotRect: CGRect,
        xDomain: ClosedRange<Date>,
    ) {
        guard end > start else { return }
        let xStart = xPosition(for: start, in: plotRect, xDomain: xDomain)
        let xEnd = xPosition(for: end, in: plotRect, xDomain: xDomain)
        let rect = CGRect(
            x: min(xStart, xEnd),
            y: plotRect.minY,
            width: max(1, abs(xEnd - xStart)),
            height: plotRect.height,
        )
        guard rect.width >= 2 else { return }

        context.fill(Path(rect), with: .color(Color.gray.opacity(0.032)))
        drawGapBoundary(at: rect.minX, in: &context, plotRect: plotRect)
        drawGapBoundary(at: rect.maxX, in: &context, plotRect: plotRect)
        drawNoSamplesLabel(in: rect, context: &context)
    }

    private func drawGapBoundary(
        at x: CGFloat,
        in context: inout GraphicsContext,
        plotRect: CGRect,
    ) {
        guard x > plotRect.minX + 1, x < plotRect.maxX - 1 else { return }

        let boundaryRect = CGRect(
            x: x - 1.25,
            y: plotRect.minY,
            width: 2.5,
            height: plotRect.height,
        )
        context.fill(
            Path(roundedRect: boundaryRect, cornerRadius: 1.25),
            with: .color(Color.gray.opacity(0.09)),
        )

        var path = Path()
        path.move(to: CGPoint(x: x, y: plotRect.minY))
        path.addLine(to: CGPoint(x: x, y: plotRect.maxY))
        context.stroke(
            path,
            with: .color(Color.gray.opacity(0.34)),
            style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [4, 5]),
        )
    }

    private func drawNoSamplesLabel(
        in gapRect: CGRect,
        context: inout GraphicsContext,
    ) {
        let labelSize = CGSize(width: 86, height: 24)
        guard gapRect.width >= labelSize.width + 28 else { return }
        guard gapRect.height >= labelSize.height + 16 else { return }

        let labelRect = CGRect(
            x: gapRect.midX - labelSize.width * 0.5,
            y: gapRect.midY - labelSize.height * 0.5,
            width: labelSize.width,
            height: labelSize.height,
        )
        let labelPath = Path(roundedRect: labelRect, cornerRadius: 8)
        context.fill(labelPath, with: .color(Color.gray.opacity(0.075)))
        context.stroke(labelPath, with: .color(Color.gray.opacity(0.11)), lineWidth: 0.5)
        context.draw(
            Text("No samples")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary),
            at: CGPoint(x: labelRect.midX, y: labelRect.midY),
            anchor: .center,
        )
    }

    private func drawLineSeries(
        _ line: HistoryTimeSparklineSeries,
        buckets orderedBuckets: [MetricHistoryBucket],
        in context: inout GraphicsContext,
        plotRect: CGRect,
        xDomain: ClosedRange<Date>,
        yDomain: ClosedRange<Double>,
    ) {
        var segment: [CGPoint] = []
        var previousBucket: MetricHistoryBucket?
        for bucket in orderedBuckets {
            if let previousBucket {
                let gap = bucket.startDate.timeIntervalSince(previousBucket.startDate)
                if gap > solidContinuityTolerance(previous: previousBucket, current: bucket) {
                    drawSegment(segment, line: line, in: &context, plotRect: plotRect)

                    if gap <= bridgeContinuityTolerance(previous: previousBucket, current: bucket) {
                        drawBridge(
                            from: previousBucket,
                            to: bucket,
                            line: line,
                            in: &context,
                            plotRect: plotRect,
                            xDomain: xDomain,
                            yDomain: yDomain,
                        )
                    }

                    segment.removeAll(keepingCapacity: true)
                }
            }

            segment.append(projected(
                bucket: bucket,
                plotRect: plotRect,
                xDomain: xDomain,
                yDomain: yDomain,
            ))
            previousBucket = bucket
        }
        drawSegment(segment, line: line, in: &context, plotRect: plotRect)
    }

    private func drawThresholdPeakMarkers(
        _ line: HistoryTimeSparklineSeries,
        buckets orderedBuckets: [MetricHistoryBucket],
        in context: inout GraphicsContext,
        plotRect: CGRect,
        xDomain: ClosedRange<Date>,
        yDomain: ClosedRange<Double>,
    ) {
        for bucket in orderedBuckets {
            guard bucket.max.isFinite,
                  bucket.avg.isFinite,
                  bucket.max > bucket.avg + peakMarkerMinimumDelta,
                  let tint = thresholdTint(for: bucket.max)
            else { continue }

            let averagePoint = projected(
                bucket: bucket,
                value: bucket.avg,
                plotRect: plotRect,
                xDomain: xDomain,
                yDomain: yDomain,
            )
            let peakPoint = projected(
                bucket: bucket,
                value: bucket.max,
                plotRect: plotRect,
                xDomain: xDomain,
                yDomain: yDomain,
            )
            let animated = verticallyAnimated([averagePoint, peakPoint], in: plotRect)
            guard animated.count == 2 else { continue }

            var wick = Path()
            wick.move(to: animated[0])
            wick.addLine(to: animated[1])
            context.stroke(
                wick,
                with: .color(tint.opacity(0.65)),
                style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 3]),
            )

            let radius: CGFloat = 3.5
            context.fill(
                Path(ellipseIn: CGRect(
                    x: animated[1].x - radius,
                    y: animated[1].y - radius,
                    width: radius * 2,
                    height: radius * 2,
                )),
                with: .color(tint.opacity(0.9)),
            )
        }
    }

    private func solidContinuityTolerance(
        previous: MetricHistoryBucket,
        current: MetricHistoryBucket,
    ) -> TimeInterval {
        max(max(previous.resolution, current.resolution) * 3, range.solidLineTolerance)
    }

    private func bridgeContinuityTolerance(
        previous: MetricHistoryBucket,
        current: MetricHistoryBucket,
    ) -> TimeInterval {
        max(max(previous.resolution, current.resolution) * 3, range.bridgeLineTolerance)
    }

    private func thresholdTint(for value: Double) -> Color? {
        thresholdBands
            .sorted { $0.lowerBound > $1.lowerBound }
            .first { value >= $0.lowerBound }?
            .tint
            .color
    }

    private func thresholdPeakValue(for bucket: MetricHistoryBucket) -> Double? {
        guard bucket.max.isFinite,
              bucket.avg.isFinite,
              bucket.max > bucket.avg + peakMarkerMinimumDelta,
              thresholdTint(for: bucket.max) != nil
        else { return nil }
        return bucket.max
    }

    private func drawBarSeries(
        _ line: HistoryTimeSparklineSeries,
        buckets orderedBuckets: [MetricHistoryBucket],
        index: Int,
        count: Int,
        in context: inout GraphicsContext,
        plotRect: CGRect,
        xDomain: ClosedRange<Date>,
        yDomain: ClosedRange<Double>,
    ) {
        let xSpan = max(xDomain.upperBound.timeIntervalSince(xDomain.lowerBound), 0.001)
        for bucket in orderedBuckets {
            guard bucket.avg > yDomain.lowerBound else { continue }
            let point = projected(
                bucket: bucket,
                plotRect: plotRect,
                xDomain: xDomain,
                yDomain: yDomain,
            )
            let naturalWidth = plotRect.width * bucket.resolution / xSpan
            let groupWidth = min(max(naturalWidth * 0.82, 5), 24)
            let spacing: CGFloat = count > 1 ? 2 : 0
            let barWidth = max(2, (groupWidth - spacing * CGFloat(count - 1)) / CGFloat(count))
            let x = point.x - groupWidth * 0.5 + CGFloat(index) * (barWidth + spacing)
            let animatedHeight = max(0, (plotRect.maxY - point.y) * CGFloat(drawProgress))
            guard animatedHeight > 0 else { continue }
            let rect = CGRect(
                x: x,
                y: plotRect.maxY - animatedHeight,
                width: barWidth,
                height: animatedHeight,
            )
            context.fill(
                Path(roundedRect: rect, cornerRadius: min(2.5, barWidth * 0.5)),
                with: .color(line.color.opacity(0.82)),
            )
        }
    }

    private func drawSegment(
        _ points: [CGPoint],
        line: HistoryTimeSparklineSeries,
        in context: inout GraphicsContext,
        plotRect: CGRect,
    ) {
        let points = verticallyAnimated(points, in: plotRect)
        guard let first = points.first else { return }
        guard points.count >= 2 else {
            let radius = max(lineWidth, 1.5)
            context.fill(
                Path(ellipseIn: CGRect(
                    x: first.x - radius,
                    y: first.y - radius,
                    width: radius * 2,
                    height: radius * 2,
                )),
                with: .color(line.color),
            )
            return
        }

        var areaPath = Path()
        areaPath.move(to: CGPoint(x: first.x, y: plotRect.maxY))
        for point in points {
            areaPath.addLine(to: point)
        }
        areaPath.addLine(to: CGPoint(x: points.last!.x, y: plotRect.maxY))
        areaPath.closeSubpath()

        context.fill(
            areaPath,
            with: .linearGradient(
                Gradient(colors: [
                    line.color.opacity(line.fillOpacity),
                    line.color.opacity(0),
                ]),
                startPoint: CGPoint(x: plotRect.midX, y: plotRect.minY),
                endPoint: CGPoint(x: plotRect.midX, y: plotRect.maxY),
            ),
        )

        var linePath = Path()
        linePath.move(to: first)
        for point in points.dropFirst() {
            linePath.addLine(to: point)
        }
        context.stroke(
            linePath,
            with: .color(line.color),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round),
        )
    }

    private func drawBridge(
        from previous: MetricHistoryBucket,
        to current: MetricHistoryBucket,
        line: HistoryTimeSparklineSeries,
        in context: inout GraphicsContext,
        plotRect: CGRect,
        xDomain: ClosedRange<Date>,
        yDomain: ClosedRange<Double>,
    ) {
        let points = verticallyAnimated([
            projected(bucket: previous, plotRect: plotRect, xDomain: xDomain, yDomain: yDomain),
            projected(bucket: current, plotRect: plotRect, xDomain: xDomain, yDomain: yDomain),
        ], in: plotRect)
        guard points.count == 2 else { return }

        var path = Path()
        path.move(to: points[0])
        path.addLine(to: points[1])

        context.stroke(
            path,
            with: .color(line.color.opacity(0.34)),
            style: StrokeStyle(
                lineWidth: max(1, lineWidth * 0.75),
                lineCap: .round,
                lineJoin: .round,
                dash: [5, 6],
            ),
        )
    }

    private func verticallyAnimated(_ points: [CGPoint], in plotRect: CGRect) -> [CGPoint] {
        guard drawProgress < 0.999 else { return points }
        let progress = CGFloat(drawProgress)
        return points.map { point in
            CGPoint(
                x: point.x,
                y: plotRect.maxY - (plotRect.maxY - point.y) * progress,
            )
        }
    }

    private func plotRect(for size: CGSize) -> CGRect {
        let strokeInset = min(max(lineWidth * 0.5, 1), min(size.width, size.height) * 0.25)
        let top = max(strokeInset, 10)
        let leading: CGFloat = 58
        let bottom: CGFloat = 36
        let trailing: CGFloat = 22
        return CGRect(
            x: leading,
            y: top,
            width: max(1, size.width - leading - trailing),
            height: max(1, size.height - top - bottom),
        )
    }

    private func drawCoordinatePlane(
        in context: inout GraphicsContext,
        plotRect: CGRect,
        xDomain: ClosedRange<Date>,
        yDomain: ClosedRange<Double>,
    ) {
        drawThresholdBands(in: &context, plotRect: plotRect, yDomain: yDomain)

        let gridColor = Color.gray.opacity(0.13)
        for tick in yTicks(for: yDomain) {
            let y = yPosition(for: tick, in: plotRect, yDomain: yDomain)
            var path = Path()
            path.move(to: CGPoint(x: plotRect.minX, y: y))
            path.addLine(to: CGPoint(x: plotRect.maxX, y: y))
            context.stroke(path, with: .color(gridColor), lineWidth: 0.5)
        }

        for tick in xTicks(for: xDomain) {
            let x = xPosition(for: tick, in: plotRect, xDomain: xDomain)
            var path = Path()
            path.move(to: CGPoint(x: x, y: plotRect.minY))
            path.addLine(to: CGPoint(x: x, y: plotRect.maxY))
            context.stroke(path, with: .color(gridColor.opacity(0.75)), lineWidth: 0.5)
        }
    }

    private func drawThresholdBands(
        in context: inout GraphicsContext,
        plotRect: CGRect,
        yDomain: ClosedRange<Double>,
    ) {
        for band in thresholdBands {
            let lower = max(band.lowerBound, yDomain.lowerBound)
            let upper = min(band.upperBound, yDomain.upperBound)
            guard upper > lower else { continue }

            let yTop = yPosition(for: upper, in: plotRect, yDomain: yDomain)
            let yBottom = yPosition(for: lower, in: plotRect, yDomain: yDomain)
            let rect = CGRect(
                x: plotRect.minX,
                y: min(yTop, yBottom),
                width: plotRect.width,
                height: max(1, abs(yBottom - yTop)),
            )
            context.fill(Path(rect), with: .color(band.tint.color.opacity(0.055)))

            let thresholdY = yPosition(for: lower, in: plotRect, yDomain: yDomain)
            var thresholdLine = Path()
            thresholdLine.move(to: CGPoint(x: plotRect.minX, y: thresholdY))
            thresholdLine.addLine(to: CGPoint(x: plotRect.maxX, y: thresholdY))
            context.stroke(
                thresholdLine,
                with: .color(band.tint.color.opacity(0.34)),
                style: StrokeStyle(lineWidth: 0.7, dash: [4, 4]),
            )
        }
    }

    private func drawAxes(
        in context: inout GraphicsContext,
        plotRect: CGRect,
        xDomain: ClosedRange<Date>,
        yDomain: ClosedRange<Double>,
    ) {
        let axisColor = Color.gray.opacity(0.36)
        var yAxis = Path()
        yAxis.move(to: CGPoint(x: plotRect.minX, y: plotRect.minY))
        yAxis.addLine(to: CGPoint(x: plotRect.minX, y: plotRect.maxY))
        context.stroke(yAxis, with: .color(axisColor), lineWidth: 0.8)

        var xAxis = Path()
        xAxis.move(to: CGPoint(x: plotRect.minX, y: plotRect.maxY))
        xAxis.addLine(to: CGPoint(x: plotRect.maxX, y: plotRect.maxY))
        context.stroke(xAxis, with: .color(axisColor), lineWidth: 0.8)

        for tick in yTicks(for: yDomain) {
            let y = yPosition(for: tick, in: plotRect, yDomain: yDomain)
            var tickPath = Path()
            tickPath.move(to: CGPoint(x: plotRect.minX - 4, y: y))
            tickPath.addLine(to: CGPoint(x: plotRect.minX, y: y))
            context.stroke(tickPath, with: .color(axisColor), lineWidth: 0.8)

            context.draw(
                Text(formatMetricValue(tick, unit: unit))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary),
                at: CGPoint(x: plotRect.minX - 8, y: y),
                anchor: .trailing,
            )
        }

        let ticks = xTicks(for: xDomain)
        for (index, tick) in ticks.enumerated() {
            let x = xPosition(for: tick, in: plotRect, xDomain: xDomain)
            var tickPath = Path()
            tickPath.move(to: CGPoint(x: x, y: plotRect.maxY))
            tickPath.addLine(to: CGPoint(x: x, y: plotRect.maxY + 4))
            context.stroke(tickPath, with: .color(axisColor), lineWidth: 0.8)

            context.draw(
                Text(timeLabel(for: tick, domain: xDomain))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary),
                at: CGPoint(x: x, y: plotRect.maxY + 16),
                anchor: xTickLabelAnchor(index: index, count: ticks.count),
            )
        }
    }

    private func hoverSnapshot(
        location: CGPoint?,
        size: CGSize,
        xDomain: ClosedRange<Date>,
        yDomain: ClosedRange<Double>,
    ) -> HistoryChartHoverSnapshot? {
        guard let location else { return nil }
        let plotRect = plotRect(for: size)
        guard plotRect.contains(location) else { return nil }

        let date = date(forX: location.x, in: plotRect, xDomain: xDomain)
        let items = series.compactMap { line -> HistoryChartHoverItem? in
            guard let bucket = nearestBucket(to: date, in: line.buckets, xDomain: xDomain) else { return nil }
            return HistoryChartHoverItem(
                id: line.id,
                label: line.label,
                value: bucket.avg,
                peakValue: thresholdPeakValue(for: bucket),
                unit: bucket.unit,
                color: line.color,
                point: projected(bucket: bucket, plotRect: plotRect, xDomain: xDomain, yDomain: yDomain),
            )
        }
        guard !items.isEmpty else { return nil }

        return HistoryChartHoverSnapshot(
            x: xPosition(for: date, in: plotRect, xDomain: xDomain),
            date: date,
            items: items,
        )
    }

    private func date(
        forX x: CGFloat,
        in plotRect: CGRect,
        xDomain: ClosedRange<Date>,
    ) -> Date {
        let xSpan = max(xDomain.upperBound.timeIntervalSince(xDomain.lowerBound), 0.001)
        let fraction = Double(min(max((x - plotRect.minX) / max(plotRect.width, 1), 0), 1))
        return xDomain.lowerBound.addingTimeInterval(xSpan * fraction)
    }

    private func nearestBucket(
        to date: Date,
        in buckets: [MetricHistoryBucket],
        xDomain: ClosedRange<Date>,
    ) -> MetricHistoryBucket? {
        let candidates = buckets
            .filter { $0.avg.isFinite && bucketOverlaps($0, xDomain: xDomain) }
        guard !candidates.isEmpty else { return nil }

        let best = candidates.min {
            bucketDistance(from: date, to: $0) < bucketDistance(from: date, to: $1)
        }
        guard let best else { return nil }

        let tolerance = max(best.resolution * 4, range.hoverSnapTolerance)
        guard bucketDistance(from: date, to: best) <= tolerance else { return nil }
        return best
    }

    private func bucketDistance(from date: Date, to bucket: MetricHistoryBucket) -> TimeInterval {
        let start = bucket.startDate
        let end = start.addingTimeInterval(bucket.resolution)
        if date < start {
            return start.timeIntervalSince(date)
        }
        if date > end {
            return date.timeIntervalSince(end)
        }
        return 0
    }

    private func restartAnimation() {
        drawProgress = 0
        withAnimation(.easeOut(duration: 0.65)) {
            drawProgress = 1
        }
    }

    private func projected(
        bucket: MetricHistoryBucket,
        plotRect: CGRect,
        xDomain: ClosedRange<Date>,
        yDomain: ClosedRange<Double>,
    ) -> CGPoint {
        projected(
            bucket: bucket,
            value: bucket.avg,
            plotRect: plotRect,
            xDomain: xDomain,
            yDomain: yDomain,
        )
    }

    private func projected(
        bucket: MetricHistoryBucket,
        value: Double,
        plotRect: CGRect,
        xDomain: ClosedRange<Date>,
        yDomain: ClosedRange<Double>,
    ) -> CGPoint {
        let xSpan = max(xDomain.upperBound.timeIntervalSince(xDomain.lowerBound), 0.001)
        let x = xPosition(for: bucketMidpoint(bucket), in: plotRect, xDomain: xDomain, xSpan: xSpan)
        let y = yPosition(for: value, in: plotRect, yDomain: yDomain)
        return CGPoint(x: x, y: y)
    }

    private func bucketMidpoint(_ bucket: MetricHistoryBucket) -> Date {
        bucket.startDate.addingTimeInterval(bucket.resolution * 0.5)
    }

    private func xPosition(
        for date: Date,
        in plotRect: CGRect,
        xDomain: ClosedRange<Date>,
        xSpan: TimeInterval? = nil,
    ) -> CGFloat {
        let span = max(xSpan ?? xDomain.upperBound.timeIntervalSince(xDomain.lowerBound), 0.001)
        let fraction = date.timeIntervalSince(xDomain.lowerBound) / span
        return plotRect.minX + CGFloat(min(max(fraction, 0), 1)) * plotRect.width
    }

    private func yPosition(
        for value: Double,
        in plotRect: CGRect,
        yDomain: ClosedRange<Double>,
    ) -> CGFloat {
        let ySpan = yDomain.upperBound - yDomain.lowerBound
        let yFrac = (value - yDomain.lowerBound) / max(ySpan, 0.001)
        return plotRect.maxY - CGFloat(min(max(yFrac, 0), 1)) * plotRect.height
    }

    private func xTicks(for domain: ClosedRange<Date>) -> [Date] {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        return [0.0, 0.5, 1.0].map {
            domain.lowerBound.addingTimeInterval(span * $0)
        }
    }

    private func xTickLabelAnchor(index: Int, count: Int) -> UnitPoint {
        if index == 0 {
            return .topLeading
        }
        if index == count - 1 {
            return .topTrailing
        }
        return .top
    }

    private func yTicks(for domain: ClosedRange<Double>) -> [Double] {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return [domain.lowerBound] }
        return (0 ... 4).map {
            domain.lowerBound + span * Double($0) / 4
        }
    }

    private func timeLabel(for date: Date, domain: ClosedRange<Date>) -> String {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        if span < 5 * 60 {
            return date.formatted(.dateTime.hour().minute().second())
        }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func resolvedXDomain() -> ClosedRange<Date> {
        let fullLower = capturedAt.addingTimeInterval(-range.duration)
        let fullUpper = capturedAt
        var first = Date.distantFuture
        var last = Date.distantPast

        for line in series {
            for bucket in line.buckets where bucket.avg.isFinite {
                let bucketStart = bucket.startDate
                let bucketEnd = bucket.startDate.addingTimeInterval(bucket.resolution)
                guard bucketEnd >= fullLower, bucketStart <= fullUpper else { continue }
                first = min(first, max(bucketStart, fullLower))
                last = max(last, min(bucketEnd, fullUpper))
            }
        }

        guard first <= last else { return fullLower ... fullUpper }

        let rawSpan = max(last.timeIntervalSince(first), range.bucketInterval)
        let minimumSpan = min(range.duration, max(range.bucketInterval * 12, 60))
        let targetSpan = min(range.duration, max(rawSpan * 1.12, minimumSpan))
        var lower = first.addingTimeInterval(-(targetSpan - rawSpan) * 0.5)
        var upper = lower.addingTimeInterval(targetSpan)

        if lower < fullLower {
            lower = fullLower
            upper = lower.addingTimeInterval(targetSpan)
        }
        if upper > fullUpper {
            upper = fullUpper
            lower = upper.addingTimeInterval(-targetSpan)
        }
        if lower < fullLower {
            lower = fullLower
        }

        return lower ... max(upper, lower.addingTimeInterval(1))
    }

    private func resolvedYDomain() -> ClosedRange<Double> {
        var minValue: Double = .greatestFiniteMagnitude
        var maxValue: Double = -.greatestFiniteMagnitude

        for line in series {
            for bucket in line.buckets {
                if bucket.min.isFinite {
                    minValue = min(minValue, bucket.min)
                }
                if bucket.max.isFinite {
                    maxValue = max(maxValue, bucket.max)
                }
            }
        }

        let lower = yMin ?? (minValue == .greatestFiniteMagnitude ? 0 : minValue)
        guard maxValue != -.greatestFiniteMagnitude else {
            return lower ... max(yMax ?? 1, lower + 1)
        }

        if unit == .percent, lower == 0, yMax == 100 {
            return lower ... percentUpperBound(for: maxValue)
        }

        let upperBase: Double = {
            if let yMax { return yMax }
            let semanticThreshold = thresholdBands
                .filter { maxValue >= $0.lowerBound * 0.9 }
                .map(\.upperBound)
                .max()
            return max(maxValue * 1.15, semanticThreshold ?? 0)
        }()
        return lower ... max(upperBase, lower + 1)
    }

    private func percentUpperBound(for maxValue: Double) -> Double {
        let padded = max(maxValue * 1.18, 1)
        for step in [25.0, 50.0, 75.0, 100.0] where padded <= step {
            return step
        }
        return 100
    }
}

private struct HistoryEventPanel: View {
    let events: [HistoryAnomalyEvent]
    let supportsAnomalies: Bool

    private var orderedEvents: [HistoryAnomalyEvent] {
        events.sorted {
            if $0.severity != $1.severity {
                return $0.severity > $1.severity
            }
            return $0.startDate > $1.startDate
        }
    }

    @ViewBuilder
    var body: some View {
        if events.isEmpty {
            compactEmptyPanel
        } else {
            expandedPanel
        }
    }

    private var compactEmptyPanel: some View {
        HStack(spacing: 10) {
            Text("Anomalies")
                .font(.headline)
                .lineLimit(1)

            if supportsAnomalies {
                countBadge
            }

            Spacer(minLength: 12)

            Text(supportsAnomalies ? "No anomalies in this range" : "Not monitored for anomalies")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.gray.opacity(0.18), lineWidth: 0.5)
        }
    }

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Anomalies")
                    .font(.headline)
                Spacer()
                countBadge
            }

            VStack(spacing: 0) {
                ForEach(Array(orderedEvents.enumerated()), id: \.element.id) { index, event in
                    HistoryEventRow(event: event)
                    if index < orderedEvents.count - 1 {
                        Divider().opacity(0.5)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.gray.opacity(0.18), lineWidth: 0.5)
        }
    }

    private var countBadge: some View {
        Text("\(events.count)")
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: .capsule)
    }
}

private struct HistoryEventRow: View {
    let event: HistoryAnomalyEvent

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: event.kind.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(event.severity.tint)
                .padding(7)
                .background(event.severity.tint.opacity(0.14), in: .rect(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(event.kind.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(event.severity.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(event.severity.tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(event.severity.tint.opacity(0.12), in: .capsule)
                }
                Text(event.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                Text(peakValueText)
                    .font(.callout.monospacedDigit().weight(.medium))
                    .lineLimit(1)
                Text(timeRange)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 10)
    }

    private var timeRange: String {
        let start = event.startDate.formatted(date: .omitted, time: .shortened)
        let end = event.endDate.formatted(date: .omitted, time: .shortened)
        return "\(start) - \(end)"
    }

    private var peakValueText: String {
        if event.metricKind == .memoryPressureLevel {
            return memoryPressureLabel(Int(event.peakValue))
        }
        return formatMetricValue(event.peakValue, unit: event.unit)
    }
}

private extension HistoryAnomalyKind {
    var title: String {
        switch self {
        case .cpuSustainedHigh: "CPU sustained high"
        case .gpuSustainedHigh: "GPU sustained high"
        case .memoryPressure: "Memory pressure"
        case .memorySwapHigh: "Swap elevated"
        case .powerSustainedHigh: "Power sustained high"
        case .diskReadSustainedHigh: "Disk read sustained"
        case .diskWriteSustainedHigh: "Disk write sustained"
        case .networkInSustainedHigh: "Network receive sustained"
        case .networkOutSustainedHigh: "Network send sustained"
        case .thermalCPUHigh: "CPU thermal high"
        case .thermalGPUHigh: "GPU thermal high"
        }
    }

    var systemImage: String {
        switch self {
        case .cpuSustainedHigh: "cpu"
        case .gpuSustainedHigh: "cpu.fill"
        case .memoryPressure: "memorychip"
        case .memorySwapHigh: "arrow.left.arrow.right"
        case .powerSustainedHigh: "bolt.fill"
        case .diskReadSustainedHigh, .diskWriteSustainedHigh: "internaldrive"
        case .networkInSustainedHigh, .networkOutSustainedHigh: "network"
        case .thermalCPUHigh, .thermalGPUHigh: "thermometer.medium"
        }
    }
}

private extension HistoryAnomalySeverity {
    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }

    var tint: Color {
        switch self {
        case .low: .yellow
        case .medium: .orange
        case .high: .red
        }
    }
}

private func formatMetricValue(_ value: Double?, unit: MetricUnit) -> String {
    guard let value else { return "--" }
    switch unit {
    case .percent, .ratio:
        return String(format: "%.0f%%", value)
    case .bytes:
        return DashboardFormatting.bytesShort(value)
    case .bytesPerSecond:
        return DashboardFormatting.rateShort(value)
    case .count:
        return String(format: "%.0f", value)
    case .watts:
        return DashboardFormatting.wattsChip(value)
    case .celsius:
        return "\(Int(value.rounded()))°C"
    case .rpm:
        return String(format: "%.0f rpm", value)
    }
}

private func durationText(_ interval: TimeInterval?) -> String {
    guard let interval else { return "--" }
    let seconds = max(0, Int(interval.rounded()))
    if seconds < 60 {
        return "\(seconds)s"
    }
    let minutes = seconds / 60
    if minutes < 60 {
        return "\(minutes)m"
    }
    let hours = minutes / 60
    let remainder = minutes % 60
    if remainder == 0 {
        return "\(hours)h"
    }
    return "\(hours)h \(remainder)m"
}

private func memoryPressureLabel(_ level: Int) -> String {
    switch level {
    case 2: "Warning"
    case 4: "Urgent"
    case 8: "Critical"
    default: "Normal"
    }
}
