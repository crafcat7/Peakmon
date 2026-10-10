//
//  FrameRateObservationChart.swift
//  Peakmon
//
//  Recorded window averages with time-specific inspection. Inspection never
//  interpolates values or snaps across an interval without a measurement.
//

import PeakmonCore
import SwiftUI

struct FrameRateObservationChart: View {
    let session: FrameRateObservationSession
    let elapsed: TimeInterval
    @Binding var selectedTime: Date?

    @State private var hoverTime: Date?
    @FocusState private var isFocused: Bool

    private let duration = FrameRateObservationSession.observationDuration
    private let continuityTolerance: TimeInterval = 0.3

    var body: some View {
        let readings = visibleReadings
        let yMaximum = max(10, ceil((readings.map(\.framesPerSecond).max() ?? 0) * 1.15 / 10) * 10)

        GeometryReader { proxy in
            let plot = plotRect(for: proxy.size)

            ZStack(alignment: .topLeading) {
                Canvas(rendersAsynchronously: true) { context, size in
                    let plot = plotRect(for: size)
                    drawAxes(in: &context, plot: plot, yMaximum: yMaximum)
                    guard let startedAt = session.startedAt else { return }

                    var plotContext = context
                    plotContext.clip(to: Path(plot))
                    drawGaps(readings, startedAt: startedAt, in: &plotContext, plot: plot)
                    drawReadings(readings, startedAt: startedAt, in: &plotContext, plot: plot, yMaximum: yMaximum)
                    drawMarkers(startedAt: startedAt, in: &plotContext, plot: plot)

                    if session.endedAt == nil {
                        let x = positionX(min(duration, max(0, elapsed)), in: plot)
                        var line = Path()
                        line.move(to: CGPoint(x: x, y: plot.minY))
                        line.addLine(to: CGPoint(x: x, y: plot.maxY))
                        plotContext.stroke(line, with: .color(.secondary.opacity(0.32)), style: StrokeStyle(lineWidth: 0.8, dash: [3, 4]))
                    }
                }

                if let inspection = inspection(at: hoverTime ?? selectedTime, readings: readings, plot: plot, yMaximum: yMaximum) {
                    FrameRateInspectionOverlay(inspection: inspection, plot: plot)
                }
            }
            .contentShape(.rect)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverTime = time(at: location, plot: plot)
                case .ended:
                    hoverTime = nil
                }
            }
            .gesture(SpatialTapGesture().onEnded { value in
                guard let time = time(at: value.location, plot: plot) else { return }
                hoverTime = nil
                selectedTime = time
                isFocused = true
            })
        }
        .clipped()
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.escape) {
            guard selectedTime != nil else { return .ignored }
            selectedTime = nil
            return .handled
        }
        .onChange(of: selectedTime) { _, time in
            if time != nil {
                hoverTime = nil
                isFocused = true
            }
        }
        .onChange(of: session.startedAt) { _, _ in
            hoverTime = nil
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Frame rate trend")
        .accessibilityValue(accessibilityValue(for: readings))
        .accessibilityHint("Click to pin a time. Press Escape to clear.")
        .help("Click to pin a time. Press Escape to clear.")
    }

    private var visibleReadings: [FrameRateReading] {
        session.readings.sorted { $0.intervalStart < $1.intervalStart }
    }

    private func accessibilityValue(for readings: [FrameRateReading]) -> Text {
        if let time = hoverTime ?? selectedTime, let startedAt = session.startedAt {
            let seconds = String(format: "%.1f", time.timeIntervalSince(startedAt))
            var value = Text("Inspection time: \(seconds) seconds.")
            guard let reading = readings.last(where: { time >= $0.intervalStart && time <= $0.intervalEnd }) else {
                return value + Text(verbatim: " ") + Text("Not measured")
            }
            let fps = String(format: "%.1f", reading.framesPerSecond)
            let start = String(format: "%.3f", reading.intervalStart.timeIntervalSince(startedAt))
            let end = String(format: "%.3f", reading.intervalEnd.timeIntervalSince(startedAt))
            value = value + Text(verbatim: " ") + Text("Frame rate: \(fps) FPS.")
                + Text(verbatim: " ") + Text("Recorded window: \(start) to \(end) seconds.")
            if let interval = reading.frameIntervalMilliseconds {
                let milliseconds = String(format: "%.2f", interval)
                value = value + Text(verbatim: " ") + Text("Mean frame-on-glass interval: \(milliseconds) milliseconds.")
            }
            return value
        }
        guard let latest = readings.max(by: { $0.intervalEnd < $1.intervalEnd }) else {
            return Text("No reading available")
        }
        let fps = String(format: "%.1f", latest.framesPerSecond)
        let count = String(readings.count)
        return Text("Latest window: \(fps) FPS. Recorded windows: \(count).")
    }

    private func plotRect(for size: CGSize) -> CGRect {
        CGRect(x: 48, y: 12, width: max(1, size.width - 66), height: max(1, size.height - 44))
    }

    private func time(at location: CGPoint, plot: CGRect) -> Date? {
        guard let startedAt = session.startedAt, plot.contains(location) else { return nil }
        return startedAt.addingTimeInterval((location.x - plot.minX) / plot.width * duration)
    }

    private func inspection(at time: Date?, readings: [FrameRateReading], plot: CGRect, yMaximum: Double) -> FrameRateInspection? {
        guard let time, let startedAt = session.startedAt else { return nil }
        let seconds = time.timeIntervalSince(startedAt)
        guard seconds >= 0, seconds <= duration else { return nil }
        // A shared boundary belongs to the later window. No tolerance is
        // applied here: even a short measurement gap remains unmeasured.
        let reading = readings.last { time >= $0.intervalStart && time <= $0.intervalEnd }
        let x = positionX(seconds, in: plot)
        return FrameRateInspection(
            time: time,
            startedAt: startedAt,
            reading: reading,
            x: x,
            point: reading.map { CGPoint(x: x, y: positionY($0.framesPerSecond, in: plot, maximum: yMaximum)) },
            isPinned: time == selectedTime,
        )
    }

    private func drawAxes(in context: inout GraphicsContext, plot: CGRect, yMaximum: Double) {
        let grid = Color.gray.opacity(0.13)
        for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let y = plot.maxY - plot.height * fraction
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(line, with: .color(grid), lineWidth: 0.5)
            let format = yMaximum < 40 ? "%.1f" : "%.0f"
            context.draw(Text(verbatim: String(format: format, yMaximum * fraction)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary), at: CGPoint(x: plot.minX - 8, y: y), anchor: .trailing)
        }
        for seconds in [0.0, 15, 30, 45, 60] {
            let x = positionX(seconds, in: plot)
            var line = Path()
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(line, with: .color(grid.opacity(0.75)), lineWidth: 0.5)
            context.draw(Text(verbatim: "\(Int(seconds)) s").font(.caption2.monospacedDigit()).foregroundStyle(.secondary), at: CGPoint(x: x, y: plot.maxY + 16))
        }
        var axes = Path()
        axes.move(to: CGPoint(x: plot.minX, y: plot.minY))
        axes.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        axes.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        context.stroke(axes, with: .color(.gray.opacity(0.3)), lineWidth: 0.8)
    }

    private func drawGaps(_ readings: [FrameRateReading], startedAt: Date, in context: inout GraphicsContext, plot: CGRect) {
        guard !readings.isEmpty else { return }
        let endSeconds = min(duration, max(0, session.endedAt?.timeIntervalSince(startedAt) ?? elapsed))
        var coveredEnd: TimeInterval = 0
        for reading in readings {
            let start = max(0, reading.intervalStart.timeIntervalSince(startedAt))
            if start - coveredEnd > continuityTolerance {
                drawGap(from: coveredEnd, to: min(start, endSeconds), in: &context, plot: plot)
            }
            coveredEnd = max(coveredEnd, reading.intervalEnd.timeIntervalSince(startedAt))
        }
        if endSeconds - coveredEnd > continuityTolerance {
            drawGap(from: coveredEnd, to: endSeconds, in: &context, plot: plot)
        }
    }

    private func drawGap(from start: TimeInterval, to end: TimeInterval, in context: inout GraphicsContext, plot: CGRect) {
        guard end > start else { return }
        let x = positionX(start, in: plot)
        let rect = CGRect(x: x, y: plot.minY, width: positionX(end, in: plot) - x, height: plot.height)
        context.fill(Path(rect), with: .color(.gray.opacity(0.035)))
        for boundary in [rect.minX, rect.maxX] {
            var line = Path()
            line.move(to: CGPoint(x: boundary, y: plot.minY))
            line.addLine(to: CGPoint(x: boundary, y: plot.maxY))
            context.stroke(line, with: .color(.gray.opacity(0.25)), style: StrokeStyle(lineWidth: 0.7, dash: [4, 5]))
        }
        if rect.width >= 100 {
            context.draw(Text("Not measured").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: rect.midX, y: rect.midY))
        }
    }

    private func drawReadings(_ readings: [FrameRateReading], startedAt: Date, in context: inout GraphicsContext, plot: CGRect, yMaximum: Double) {
        var points: [CGPoint] = []
        var previous: FrameRateReading?
        for reading in readings {
            let start = min(duration, max(0, reading.intervalStart.timeIntervalSince(startedAt)))
            let end = min(duration, max(0, reading.intervalEnd.timeIntervalSince(startedAt)))
            guard end > start else { continue }
            if let previous, reading.intervalStart.timeIntervalSince(previous.intervalEnd) > continuityTolerance {
                drawSegment(points, in: &context, plot: plot)
                points.removeAll(keepingCapacity: true)
            }
            let y = positionY(reading.framesPerSecond, in: plot, maximum: yMaximum)
            points.append(CGPoint(x: positionX(start, in: plot), y: y))
            points.append(CGPoint(x: positionX(end, in: plot), y: y))
            previous = reading
        }
        drawSegment(points, in: &context, plot: plot)
    }

    private func drawSegment(_ points: [CGPoint], in context: inout GraphicsContext, plot: CGRect) {
        guard let first = points.first, let last = points.last else { return }
        var area = Path()
        area.move(to: CGPoint(x: first.x, y: plot.maxY))
        for point in points { area.addLine(to: point) }
        area.addLine(to: CGPoint(x: last.x, y: plot.maxY))
        area.closeSubpath()
        context.fill(area, with: .linearGradient(Gradient(colors: [.accentColor.opacity(0.12), .accentColor.opacity(0)]), startPoint: CGPoint(x: plot.midX, y: plot.minY), endPoint: CGPoint(x: plot.midX, y: plot.maxY)))
        var line = Path()
        line.move(to: first)
        for point in points.dropFirst() { line.addLine(to: point) }
        context.stroke(line, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        context.fill(Path(ellipseIn: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)), with: .color(.accentColor))
    }

    private func drawMarkers(startedAt: Date, in context: inout GraphicsContext, plot: CGRect) {
        for marker in session.markers {
            let seconds = marker.timestamp.timeIntervalSince(startedAt)
            guard seconds >= 0, seconds <= duration else { continue }
            let selected = selectedTime.map { abs($0.timeIntervalSince(marker.timestamp)) < 0.001 } ?? false
            let x = positionX(seconds, in: plot)
            var line = Path()
            line.move(to: CGPoint(x: x, y: plot.minY))
            line.addLine(to: CGPoint(x: x, y: plot.maxY))
            context.stroke(line, with: .color(.orange.opacity(selected ? 0.95 : 0.55)), style: StrokeStyle(lineWidth: selected ? 1.6 : 0.8, dash: selected ? [] : [3, 4]))
            context.fill(Path(ellipseIn: CGRect(x: x - (selected ? 3 : 2), y: plot.minY, width: selected ? 6 : 4, height: selected ? 6 : 4)), with: .color(.orange))
        }
    }

    private func positionX(_ seconds: TimeInterval, in plot: CGRect) -> CGFloat {
        plot.minX + plot.width * seconds / duration
    }

    private func positionY(_ fps: Double, in plot: CGRect, maximum: Double) -> CGFloat {
        plot.maxY - plot.height * min(1, max(0, fps / maximum))
    }
}

private struct FrameRateInspection {
    let time: Date
    let startedAt: Date
    let reading: FrameRateReading?
    let x: CGFloat
    let point: CGPoint?
    let isPinned: Bool
}

private struct FrameRateInspectionOverlay: View {
    let inspection: FrameRateInspection
    let plot: CGRect

    private var tooltipWidth: CGFloat { min(238, max(130, plot.width - 16)) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: inspection.x, y: plot.minY))
                path.addLine(to: CGPoint(x: inspection.x, y: plot.maxY))
            }
            .stroke(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 0.8, dash: [4, 4]))

            if let point = inspection.point {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
                    .overlay { Circle().stroke(.background, lineWidth: 2) }
                    .position(point)
            }

            tooltip
                .frame(width: tooltipWidth, alignment: .leading)
                .offset(x: tooltipX, y: plot.minY + 8)
        }
        .allowsHitTesting(false)
    }

    private var tooltip: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(verbatim: String(format: "%.1f s", inspection.time.timeIntervalSince(inspection.startedAt)))
                    .font(.caption.monospacedDigit().weight(.medium))
                Spacer(minLength: 6)
                if inspection.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .accessibilityLabel("Pinned inspection")
                }
            }
            .foregroundStyle(.secondary)

            if let reading = inspection.reading {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(verbatim: String(format: "%.1f", reading.framesPerSecond))
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("FPS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text("Recorded window")
                    Spacer(minLength: 4)
                    Text(verbatim: String(format: "%.3f–%.3f s", reading.intervalStart.timeIntervalSince(inspection.startedAt), reading.intervalEnd.timeIntervalSince(inspection.startedAt)))
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                if let interval = reading.frameIntervalMilliseconds {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Mean frame-on-glass interval")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Text(verbatim: String(format: "%.2f ms", interval))
                            .monospacedDigit()
                            .fixedSize()
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            } else {
                Text("Not measured")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: .rect(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).stroke(Color.gray.opacity(0.24), lineWidth: 0.5) }
    }

    private var tooltipX: CGFloat {
        let preferred = inspection.x > plot.midX ? inspection.x - tooltipWidth - 12 : inspection.x + 12
        return min(max(preferred, plot.minX), max(plot.minX, plot.maxX - tooltipWidth))
    }
}
