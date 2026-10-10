// One observation workspace. Controls stay available while the result scrolls;
// collection is owned by the app, independent of this surface's lifetime.

import AppKit
import PeakmonCore
import PeakmonUI
import SwiftUI

struct FrameRateSurface: View {
    @Environment(FrameRateObservationStore.self) private var observation
    @Environment(\.locale) private var locale
    @State private var visibility = MainWindowVisibility.shared
    @State private var selectedTime: Date?
    @State private var showsDetails = false
    @State private var controlBarHeight: CGFloat = 86
    @FocusState private var focusedScope: FrameRateScope?
    @Namespace private var scopeNamespace

    var body: some View {
        Group {
            if visibility.isMainWindowActive {
                activeContent
            } else {
                Color.clear
            }
        }
        .task {
            if observation.session.startedAt == nil {
                observation.refreshApplications()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            observation.refreshApplications()
        }
        .onChange(of: observation.scope) { _, _ in observation.selectionChanged() }
        .onChange(of: observation.selectedApplicationID) { _, _ in observation.selectionChanged() }
        .onChange(of: observation.selectedSourceID) { _, _ in observation.selectionChanged() }
        .onChange(of: observation.session.startedAt) { _, _ in selectedTime = nil }
    }

    private var activeContent: some View {
        GeometryReader { proxy in
            let markerHeight: CGFloat = observation.session.markers.isEmpty ? 0 : 44
            let chartHeight = min(300, max(160, proxy.size.height - controlBarHeight - 12 - 254 - markerHeight))

            VStack(spacing: 12) {
                controlBar
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlBarHeight = $0 }
                ScrollView {
                    resultPanel(chartHeight: chartHeight)
                        .padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: 1_600, alignment: .topLeading)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Label("Frame observation", systemImage: "film")
                    .font(.headline)

                scopePicker

                Spacer(minLength: 12)

                primaryAction

                Button {
                    showsDetails.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help("Observation details")
                .accessibilityLabel("Observation details")
                .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                    observationDetails
                        .environment(\.locale, locale)
                }
            }

            HStack(spacing: 10) {
                if observation.scope == .desktop {
                    Label("Desktop presentation activity", systemImage: "display")
                        .font(.callout)
                } else {
                    applicationSelection
                }

                Spacer(minLength: 8)

                Label("60-second observation", systemImage: "timer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            if observation.scope == .application, !observation.applicationSupported {
                inlineNotice("Application frame rate observation is unavailable on this Mac.")
            } else if observation.sources.count > 1, observation.selectedSourceID == nil {
                inlineNotice("Choose one presentation source, then start the observation.")
            } else if let message = observation.message {
                Label {
                    Text(LocalizedStringKey(message))
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(16)
        .peakmonGlassSurface()
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.gray.opacity(0.18), lineWidth: 0.5)
        }
    }

    private var scopePicker: some View {
        HStack(spacing: 4) {
            scopeButton(.desktop, title: "Desktop", icon: "display")
            scopeButton(.application, title: "Application", icon: "app.badge")
        }
        .padding(4)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .disabled(observation.isRunning)
        .opacity(observation.isRunning ? 0.6 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Observation target")
        .onKeyPress(.leftArrow) { focusScope(.desktop) }
        .onKeyPress(.rightArrow) { focusScope(.application) }
    }

    private func scopeButton(_ scope: FrameRateScope, title: String, icon: String) -> some View {
        let selected = observation.scope == scope
        return Button {
            _ = changeScope(scope)
        } label: {
            Label(LocalizedStringKey(title), systemImage: icon)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background {
                    if selected {
                        Capsule()
                            .fill(Color.accentColor.opacity(0.13))
                            .matchedGeometryEffect(id: "scope", in: scopeNamespace)
                            .overlay {
                                Capsule().stroke(Color.accentColor.opacity(0.18), lineWidth: 0.5)
                            }
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focused($focusedScope, equals: scope)
        .accessibilityLabel(Text(LocalizedStringKey(title)))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func changeScope(_ scope: FrameRateScope) -> KeyPress.Result {
        guard !observation.isRunning else { return .ignored }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            observation.scope = scope
        }
        return .handled
    }

    private func focusScope(_ scope: FrameRateScope) -> KeyPress.Result {
        guard focusedScope != nil, !observation.isRunning else { return .ignored }
        focusedScope = scope
        return changeScope(scope)
    }

    private var primaryAction: some View {
        Group {
            if observation.isRunning {
                Button(action: observation.stop) {
                    HStack(spacing: 6) {
                        if observation.isStopping {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "stop.fill")
                        }
                        Text(LocalizedStringKey(observation.isStopping ? "Stopping observation" : "Stop observation"))
                    }
                }
                .disabled(!observation.canStop)
            } else {
                Button(action: observation.start) {
                    Label {
                        Text(LocalizedStringKey(observation.session.startedAt == nil ? "Start observation" : "Observe again"))
                    } icon: {
                        Image(systemName: observation.session.startedAt == nil ? "play.fill" : "arrow.clockwise")
                    }
                }
                .disabled(!observation.canStart)
                .help(observation.session.startedAt == nil ? "Start observation" : "A new observation replaces these results.")
            }
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
    }

    private var applicationSelection: some View {
        @Bindable var selection = observation

        return HStack(spacing: 8) {
            Menu {
                Picker("Application", selection: $selection.selectedApplicationID) {
                    Text("Choose an application").tag(nil as String?)
                    if let selectedID = observation.selectedApplicationID,
                       !observation.applications.contains(where: { $0.id == selectedID }) {
                        Text("Selected application is no longer running")
                            .tag(Optional(selectedID))
                            .disabled(true)
                    }
                    ForEach(observation.applications) { application in
                        Text(verbatim: applicationTitle(application))
                            .tag(Optional(application.id))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                choiceLabel(applicationMenuTitle, icon: "app.badge")
                    .frame(maxWidth: 230)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("Application")
            .accessibilityValue(applicationMenuTitle)
            .help(applicationMenuTitle)
            .disabled(observation.isRunning)

            Button(action: observation.refreshApplications) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 28, height: 28)
                    .background(.quaternary.opacity(0.35), in: Circle())
            }
            .buttonStyle(.borderless)
            .help("Refresh applications")
            .accessibilityLabel("Refresh applications")
            .disabled(observation.isRunning)

            if observation.sources.count > 1 {
                Menu {
                    Picker("Presentation source", selection: $selection.selectedSourceID) {
                        Text("Choose a presentation source").tag(nil as String?)
                        ForEach(observation.sources) { source in
                            Text(verbatim: presentationSourceTitle(source))
                                .tag(Optional(source.id))
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    choiceLabel(sourceMenuTitle, icon: "rectangle.stack")
                        .frame(maxWidth: 260)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .accessibilityLabel("Presentation source")
                .accessibilityValue(sourceMenuTitle)
                .help(sourceMenuTitle)
                .disabled(observation.isRunning)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var applicationMenuTitle: Text {
        if let application = observation.applications.first(where: { $0.id == observation.selectedApplicationID }) {
            return Text(verbatim: applicationTitle(application))
        }
        return observation.selectedApplicationID == nil
            ? Text("Choose an application")
            : Text("Selected application is no longer running")
    }

    private var sourceMenuTitle: Text {
        if let source = observation.sources.first(where: { $0.id == observation.selectedSourceID }) {
            return Text(verbatim: presentationSourceTitle(source))
        }
        return Text("Choose a presentation source")
    }

    private func choiceLabel(_ title: Text, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            title
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.35), in: Capsule())
        .overlay { Capsule().stroke(Color.gray.opacity(0.18), lineWidth: 0.5) }
        .contentShape(Capsule())
        .accessibilityElement(children: .combine)
    }

    private func applicationTitle(_ application: FrameRateApplicationTarget) -> String {
        let duplicate = observation.applications.contains {
            $0.id != application.id && $0.name == application.name
        }
        return duplicate ? "\(application.name) · PID \(application.identity.pid)" : application.name
    }

    private func presentationSourceTitle(_ source: FrameRateSource) -> String {
        let ambiguous = observation.sources.contains { $0.id != source.id && $0.name == source.name }
        guard ambiguous else { return source.name }
        let process = source.processIdentity.map { " · PID \($0.pid)" } ?? ""
        return "\(source.name)\(process) · \(source.layerID?.suffix(8) ?? "")"
    }

    private func resultPanel(chartHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Label("Observation results", systemImage: "chart.xyaxis.line")
                    .font(.headline)

                Spacer(minLength: 12)

                statusIndicator

                if observation.isRunning {
                    Button(action: observation.mark) {
                        Label("Add mark", systemImage: "flag")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!observation.canMark)
                    .help(observation.session.markers.count >= 60 ? "The mark limit has been reached." : "Add mark")
                }
            }

            if observation.session.readings.isEmpty {
                emptyState
            } else {
                readingSummary
                Divider().opacity(0.45)

                HStack(spacing: 10) {
                    Text("Frame rate trend")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if selectedTime != nil {
                        Button {
                            selectedTime = nil
                        } label: {
                            Label("Clear selection", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }

                FrameRateObservationChart(
                    session: observation.session,
                    elapsed: observation.elapsed,
                    selectedTime: $selectedTime,
                )
                .frame(height: chartHeight)
            }

            if !observation.session.markers.isEmpty {
                markerRow
            }

            if !observation.session.readings.isEmpty {
                resultFooter
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .peakmonGlassSurface(tint: .indigo, tintOpacity: 0.06)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.gray.opacity(0.18), lineWidth: 0.5)
        }
    }

    private var statusIndicator: some View {
        HStack(spacing: 6) {
            if observation.isPreparing || observation.isStopping {
                ProgressView().controlSize(.mini)
            } else {
                Circle()
                    .fill(observation.isRunning ? Color.accentColor : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
            }
            Text(LocalizedStringKey(observation.statusTitle))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: observation.isRunning ? "waveform.path" : "chart.xyaxis.line")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.indigo)
                .frame(width: 44, height: 44)
                .background(.indigo.opacity(0.10), in: .rect(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(emptyTitle))
                    .font(.callout.weight(.semibold))
                Text(LocalizedStringKey(emptyDescription))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
    }

    private var emptyTitle: String {
        if observation.scope == .application, !observation.applicationSupported { return "Application observation unavailable" }
        if observation.isStopping { return "Finishing observation" }
        if observation.isPreparing { return "Finding a presentation source" }
        if observation.isRunning { return "Waiting for the first reading" }
        if observation.statusTitle != "Not started" { return "No readings recorded" }
        if observation.scope == .application, observation.selectedApplicationID == nil { return "Choose an application" }
        if observation.sources.count > 1, observation.selectedSourceID == nil { return "Choose a source to continue" }
        return "Ready to observe"
    }

    private var emptyDescription: String {
        if observation.scope == .application, !observation.applicationSupported { return "Application observation requires macOS 27 or later and a readable Metal source. You can switch to Desktop to check display activity." }
        if observation.isStopping { return "Keeping this observation's results." }
        if observation.isPreparing { return "The observation will begin when a readable source is found." }
        if observation.isRunning { return "Keep the target active. The trend appears when a valid measurement arrives." }
        if observation.statusTitle != "Not started" { return "Choose a target and try again while it is displaying new frames." }
        if observation.scope == .application, observation.selectedApplicationID == nil { return "Choose an application above, then start while it is rendering." }
        if observation.sources.count > 1, observation.selectedSourceID == nil { return "Each source is measured separately. Select one above and start." }
        return "Start here, then switch to the app or animation you want to check. Peakmon keeps recording."
    }

    private var readingSummary: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(observation.isRunning ? "Latest window" : "Last reading"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(verbatim: observation.latestReading.map { String(format: "%.1f", $0.framesPerSecond) } ?? "—")
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("FPS")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                if let source = observation.session.source {
                    Text(LocalizedStringKey(source.name))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            if let interval = observation.latestReading?.frameIntervalMilliseconds {
                FooterStatView(
                    title: "Mean frame-on-glass interval",
                    value: String(format: "%.2f ms", interval),
                    color: .primary,
                )
            }

            VStack(alignment: .trailing, spacing: 8) {
                Text(verbatim: String(format: "%.1f / 60 s", min(60, max(0, observation.elapsed))))
                    .font(.callout.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                ProportionalBarView(
                    fraction: observation.elapsed / FrameRateObservationSession.observationDuration,
                    color: .indigo,
                    height: 4,
                    backgroundOpacity: 0.12,
                )
                .frame(width: 120)
                .accessibilityLabel("Elapsed")
                .accessibilityValue(Text(verbatim: String(format: "%.1f s", observation.elapsed)))
            }
        }
    }

    private var resultFooter: some View {
        HStack(spacing: 10) {
            if observation.isRunning, let latest = observation.session.readings.last {
                Label {
                    if observation.latestReading != nil {
                        Text("Reading age")
                        + Text(verbatim: String(format: " %.1f s", max(0, Date.now.timeIntervalSince(latest.intervalEnd))))
                    } else {
                        Text("Waiting for a new reading")
                    }
                } icon: {
                    Image(systemName: observation.isDelayed ? "clock" : "checkmark.circle")
                }
            } else {
                Label("Results stay until you change the target or observe again.", systemImage: "checkmark.circle")
            }
            Spacer(minLength: 8)
            Text("Hover to inspect · Click to keep a reading")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var markerRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Text("Marks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(observation.session.markers.enumerated()), id: \.element.id) { index, marker in
                    Button {
                        selectedTime = selectedTime == marker.timestamp ? nil : marker.timestamp
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "flag.fill")
                            Text(verbatim: String(format: "%02d · %.1f s", index + 1, marker.timestamp.timeIntervalSince(observation.session.startedAt ?? marker.timestamp)))
                                .monospacedDigit()
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(.orange.opacity(selectedTime == marker.timestamp ? 0.18 : 0.08), in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(.orange.opacity(selectedTime == marker.timestamp ? 0.45 : 0.15), lineWidth: 0.5)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Mark \(index + 1)"))
                    .accessibilityValue(Text(verbatim: String(format: "%.1f s", marker.timestamp.timeIntervalSince(observation.session.startedAt ?? marker.timestamp))))
                    .accessibilityAddTraits(selectedTime == marker.timestamp ? [.isSelected] : [])
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func inlineNotice(_ key: String) -> some View {
        Label {
            Text(LocalizedStringKey(key))
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var observationDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Observation details", systemImage: "info.circle")
                .font(.headline)

            Text("What this measures")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if observation.scope == .desktop {
                Text("Display swap events from one fixed counter source. A low rate on a static desktop is expected. Application FPS and display refresh rate describe different activity.")
            } else {
                Text("Presented frames from one readable application source. Layers are never added together. An application without a readable source cannot be observed.")
            }

            Text("Each point is the average for its recorded window. Gaps mean no measurement; this chart does not score stutters.")
                .foregroundStyle(.secondary)

            if let source = observation.session.source {
                Divider()
                detailRow("Source", value: source.name)
                if let identity = source.processIdentity {
                    detailRow("PID", value: String(identity.pid))
                }
                if let layerID = source.layerID {
                    detailRow("Layer", value: layerID)
                } else {
                    detailRow("Counter source", value: source.id)
                }
                detailRow("Recorded windows", value: String(observation.session.readings.count))
                if let reading = observation.session.readings.last {
                    detailRow("Window", value: String(format: "%.2f s", reading.duration))
                }
            }
        }
        .font(.callout)
        .padding(20)
        .frame(width: 360, alignment: .leading)
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(LocalizedStringKey(title))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(LocalizedStringKey(value))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.caption)
    }
}
