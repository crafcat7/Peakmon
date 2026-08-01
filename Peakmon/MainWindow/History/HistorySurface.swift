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
    @Environment(HistoryIssuesStore.self) private var issuesStore

    @Binding var range: HistoryRange
    @Binding var selectedDefinition: HistoryMetricDefinition
    @State private var snapshot = HistorySnapshot.empty
    @State private var isRefreshing = false
    @State private var visibility = MainWindowVisibility.shared
    @State private var lastScrolledNavigationRevision = -1

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
        .onChange(of: issuesStore.navigationRevision, initial: true) { _, _ in
            guard let focusedMetric = issuesStore.focusedMetric else { return }
            selectedDefinition = focusedMetric
        }
        .task(id: refreshKey) {
            guard visibility.isMainWindowActive else { return }
            await refreshLoop(for: range)
        }
    }

    private var activeContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HistoryMetricPicker(
                        metrics: snapshot.summaries,
                        selection: $selectedDefinition,
                        range: $range,
                        capturedAt: snapshot.capturedAt,
                        isRefreshing: isRefreshing,
                        onRefresh: {
                            Task { await refreshOnce(for: range) }
                        },
                    )

                    HistoryMetricDetailPanel(
                        metric: snapshot.metric(for: selectedDefinition),
                        definition: selectedDefinition,
                        range: range,
                        capturedAt: snapshot.capturedAt,
                    )

                    HistoryEventPanel(
                        events: snapshot.events(for: selectedDefinition),
                        supportsAnomalies: !selectedDefinition.anomalyKinds.isEmpty,
                        focusedEventID: issuesStore.focusedEventID,
                    )
                }
                .frame(maxWidth: 1_600, alignment: .topLeading)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .task(id: focusScrollKey) {
                await scrollToFocusedIssue(using: proxy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var refreshKey: String {
        "\(range.rawValue)-\(selectedDefinition.rawValue)-\(visibility.isMainWindowActive)"
    }

    private var focusScrollKey: String {
        guard let focusedEventID = issuesStore.focusedEventID else {
            return "\(issuesStore.navigationRevision)-none"
        }
        let isAvailable = snapshot.events.contains { $0.id == focusedEventID }
        return "\(issuesStore.navigationRevision)-\(isAvailable)"
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
        let definition = selectedDefinition
        let next = await HistoryQueryService(recorder: recorder).read(
            range: range,
            selected: definition,
        )
        guard !Task.isCancelled, self.range == range, selectedDefinition == definition else { return }
        snapshot = next
    }

    private func scrollToFocusedIssue(using proxy: ScrollViewProxy) async {
        let revision = issuesStore.navigationRevision
        guard revision != lastScrolledNavigationRevision,
              let focusedEventID = issuesStore.focusedEventID,
              snapshot.events.contains(where: { $0.id == focusedEventID })
        else { return }

        await Task.yield()
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(focusedEventID, anchor: .center)
        }
        lastScrolledNavigationRevision = revision
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

extension HistoryMetricTint {
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

extension HistoryRange {
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

private struct HistoryMetricPicker: View {
    let metrics: [HistoryMetricSummary]
    @Binding var selection: HistoryMetricDefinition
    @Binding var range: HistoryRange
    let capturedAt: Date
    let isRefreshing: Bool
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Label("System timeline", systemImage: "chart.xyaxis.line")
                    .font(.headline)

                Spacer(minLength: 12)

                Picker("Range", selection: $range) {
                    ForEach(HistoryRange.allCases, id: \.self) { item in
                        Text(LocalizedStringKey(item.displayName)).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 24, height: 24)
                        .rotationEffect(isRefreshing ? .degrees(360) : .zero)
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
                .help("Refresh")
            }

            ViewThatFits(in: .horizontal) {
                metricRow(Array(HistoryMetricDefinition.allCases))
                    .frame(minWidth: 1_120)

                VStack(spacing: 8) {
                    metricRow(Array(HistoryMetricDefinition.allCases.prefix(4)))
                    metricRow(Array(HistoryMetricDefinition.allCases.dropFirst(4)))
                }
            }
        }
        .padding(16)
        .peakmonGlassSurface()
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.gray.opacity(0.18), lineWidth: 0.5)
        }
    }

    private func metricRow(_ definitions: [HistoryMetricDefinition]) -> some View {
        HStack(spacing: 8) {
            ForEach(definitions, id: \.self) { definition in
                Button {
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        selection = definition
                    }
                } label: {
                    metricCard(for: definition)
                }
                .buttonStyle(HistoryMetricPickerButtonStyle(
                    tint: definition.tint.color,
                    isSelected: selection == definition,
                ))
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func metricCard(for definition: HistoryMetricDefinition) -> some View {
        let metric = metrics.first { $0.definition == definition }
        let isSelected = selection == definition
        let hasData = metric != nil

        return HStack(spacing: 9) {
            Image(systemName: definition.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hasData ? definition.tint.color : .secondary)
                .frame(width: 26, height: 26)
                .background(
                    (hasData ? definition.tint.color : Color.gray).opacity(isSelected ? 0.18 : 0.10),
                    in: .rect(cornerRadius: 7),
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(definition.title))
                    .font(.caption.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(hasData ? .secondary : .tertiary)
                    .lineLimit(1)

                Text(metricHeadline(for: metric, definition: definition))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(hasData ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 9)
        .padding(.vertical, 9)
    }

    private func metricHeadline(
        for metric: HistoryMetricSummary?,
        definition: HistoryMetricDefinition,
    ) -> String {
        guard let metric else { return "--" }
        return formatMetricValue(metric.latest, unit: definition.unit)
    }
}

private struct HistoryMetricPickerButtonStyle: ButtonStyle {
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: definition.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(definition.tint.color)
                    .frame(width: 34, height: 34)
                    .background(definition.tint.color.opacity(0.15), in: .rect(cornerRadius: 8))

                Text(LocalizedStringKey(definition.title))
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)

                Spacer()
            }

            if let metric {
                HistoryMetricHero(metric: metric, definition: definition)

                HistoryTimeSparklineView(
                    series: metric.sparklineSeries,
                    range: range,
                    capturedAt: capturedAt,
                    mode: definition.chartMode,
                    unit: definition.unit,
                    lineWidth: 2,
                    yMin: 0,
                    yMax: definition.yMax,
                    thresholdBands: definition.thresholdBands,
                )
                .frame(minHeight: 270)

                Divider().opacity(0.45)

                HistorySamplingDiagnosticsStrip(
                    diagnostics: metric.diagnostics(in: range, at: capturedAt),
                )
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
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .peakmonGlassSurface(
            tint: definition.tint.color,
            tintOpacity: 0.08,
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.gray.opacity(0.18), lineWidth: 0.5)
        }
    }
}

private extension HistoryMetricSnapshot {
    var historyHeadline: Double? {
        switch definition {
        case .disk, .network:
            let values = visibleSeries.compactMap(\.latest)
            return values.isEmpty ? nil : values.reduce(0, +)
        case .cpu, .memory, .power, .gpu, .temperature, .fan:
            return latest
        }
    }
}

private struct HistoryMetricHero: View {
    let metric: HistoryMetricSnapshot
    let definition: HistoryMetricDefinition

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 26) {
            if showsTotalHeadline {
                stat(
                    label: "Latest total",
                    value: metric.historyHeadline,
                    size: 38,
                    weight: .bold,
                    color: .primary,
                )
            }

            if metric.visibleSeries.count > 1 {
                ForEach(metric.visibleSeries) { item in
                    stat(
                        label: item.definition.label,
                        value: item.latest,
                        size: showsTotalHeadline ? 20 : 30,
                        color: item.definition.tint.color,
                    )
                }
            } else {
                stat(
                    label: "Latest",
                    value: metric.latest,
                    size: 38,
                    weight: .bold,
                    color: .primary,
                )
                stat(label: "Average", value: metric.average)
                stat(label: "Peak", value: metric.peak, color: definition.tint.color)
            }

            Spacer(minLength: 0)
        }
    }

    private var showsTotalHeadline: Bool {
        switch definition {
        case .disk, .network: true
        case .cpu, .memory, .power, .gpu, .temperature, .fan: false
        }
    }

    private func stat(
        label: String,
        value: Double?,
        size: CGFloat = 20,
        weight: Font.Weight = .semibold,
        color: Color = .primary,
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(label))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(formatMetricValue(value, unit: definition.unit))
                .font(.system(size: size, weight: weight, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }
}

private struct HistorySamplingDiagnosticsStrip: View {
    let diagnostics: HistoryMetricDiagnostics

    var body: some View {
        HStack(spacing: 18) {
            item(label: "Coverage", value: coverageText)
            item(label: "Samples", value: "\(diagnostics.sampleCount)")
            item(label: "Max gap", value: durationText(diagnostics.longestGap))
            item(label: "Last seen", value: lastSeenText)
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

    private func item(label: String, value: String) -> some View {
        HStack(spacing: 5) {
            Text(LocalizedStringKey(label))
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.82)
    }
}
