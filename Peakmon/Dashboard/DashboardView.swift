//
//  DashboardView.swift
//  Peakmon
//
//  Fixed dashboard popover. Routes per-card visibility through the
//  user's persisted order and product-defined width roles, then dispatches each
//  visible slot to the matching card view. The card bodies themselves
//  now live in their own files
//  (`CPUCard.swift`, `MemoryCard.swift`, …) so this view stays a
//  pure shell.
//

import AppKit
import PeakmonCore
import PeakmonUI
import SwiftUI

struct DashboardView: View {
    var visibilityOverride: Bool? = nil
    var onShowHistory: (HistoryAnomalyEvent?) -> Void = { _ in }

    @Environment(MetricsStore.self) private var store
    @Environment(MetricsRuntime.self) private var runtime
    @Environment(HistoryIssuesStore.self) private var issuesStore
    @Environment(\.cardSettings) private var cardSettings
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppLanguage.storageKey) private var languageRawValue = AppLanguage.default.rawValue

    /// `true` only while the popover window is on-screen. Used to gate
    /// every `store.*` read so the popover stops subscribing to the
    /// `@Observable` `MetricsStore` once it is dismissed. Without this
    /// gate, `MenuBarExtra(.window)` keeps the dashboard view tree
    /// alive after the popover closes — every store ingest then forces
    /// a `body` recompute, which re-runs all sparklines, charts, and
    /// `Text` formatters, then commits a CALayer transaction whose
    /// `CGDrawingLayer.draw` rasterises every glyph again.
    @State private var isVisible = false
    @State private var popoverDemandArmed = false
    @State private var popoverDemandTask: Task<Void, Never>?

    /// Give AppKit one run-loop slice to show the popover window
    /// before turning on demand-gated collectors and Processes. That
    /// avoids stacking libproc / IOReport wake-ups onto the same frame
    /// as the popover's material and SwiftUI tree creation.
    private static let popoverDemandDelay: Duration = .milliseconds(180)

    /// A 560 pt popover leaves 532 pt inside the horizontal padding.
    /// After the gutter, each primary half-width card is 260 × 136 pt.
    /// The compact height lets the complete default dashboard fit in
    /// one opening while preserving room for two stats and a sparkline.
    static let popoverWidth: CGFloat = 560
    static let popoverHeight: CGFloat = 760

    var body: some View {
        let isContentVisible = visibilityOverride ?? isVisible
        let shouldStartDemand = isContentVisible && demandArmed
        let needsProcesses = shouldStartDemand && cardSettings.visibility(.processes)
        let collectorDemandSlots = shouldStartDemand ? configuredDemandSlots : []

        Group {
            if isContentVisible {
                visibleContent
            } else {
                // Fixed-size placeholder so the popover keeps the same
                // window geometry while hidden, and — critically — does
                // *not* read any `store.*` property so the @Observable
                // store no longer triggers `body` recomputes here.
                Color.clear.frame(width: Self.popoverWidth, height: Self.popoverHeight)
            }
        }
        .background {
            if visibilityOverride == nil {
                PopoverWindowVisibilityProbe(isVisible: $isVisible)
            }
        }
        .environment(\.locale, AppLanguage(rawValue: languageRawValue)?.locale ?? AppLanguage.default.locale)
        .onDisappear {
            disarmPopoverDemand()
            isVisible = false
            runtime.popoverVisible = false
            runtime.popoverNeedsProcesses = false
        }
        .onChange(of: isContentVisible, initial: true) { _, value in
            runtime.popoverVisible = value
            updatePopoverDemandArming(isVisible: value)
        }
        .onChange(of: collectorDemandSlots, initial: true) { _, value in
            runtime.updatePopoverConfiguredSlots(value)
        }
        .onChange(of: needsProcesses, initial: true) { _, value in
            runtime.popoverNeedsProcesses = value
        }
    }

    private var demandArmed: Bool {
        if visibilityOverride != nil {
            return isVisible || visibilityOverride == true
        }
        return popoverDemandArmed
    }

    private func updatePopoverDemandArming(isVisible: Bool) {
        popoverDemandTask?.cancel()

        guard visibilityOverride == nil else {
            popoverDemandArmed = isVisible
            return
        }

        guard isVisible else {
            popoverDemandArmed = false
            return
        }

        popoverDemandArmed = false
        popoverDemandTask = Task { @MainActor in
            try? await Task.sleep(for: Self.popoverDemandDelay)
            guard !Task.isCancelled else { return }
            popoverDemandArmed = true
        }
    }

    private func disarmPopoverDemand() {
        popoverDemandTask?.cancel()
        popoverDemandTask = nil
        popoverDemandArmed = false
    }

    /// Real popover content. Lives in its own computed property so the
    /// outer `body` does not even touch `store.*` while the popover is
    /// hidden — the SwiftUI dependency tracker then has nothing to
    /// invalidate on each `MetricsStore.ingest` tick.
    private var visibleContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(DashboardLayout.rows(from: visibleCards), id: \.rowID) { row in
                    rowView(row)
                }

                if visibleCards.isEmpty { emptyState }
            }
            .padding(.vertical, 4)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading,
            )

            footer
                .padding(.vertical, 3)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(
            width: Self.popoverWidth,
            height: Self.popoverHeight,
            alignment: .topLeading,
        )
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    /// Materialises the user's visibility preferences into the
    /// ordered card list `DashboardLayout` packs into rows. Order is
    /// configured from the lightweight preview in Display settings.
    private var visibleCards: [DashboardLayout.VisibleCard] {
        var cards: [DashboardLayout.VisibleCard] = []
        for slot in cardSettings.order()
        where cardSettings.visibility(slot) && hasData(slot) {
            cards.append(.init(
                slot: slot,
                width: CardWidth.defaultValue(for: slot),
            ))
        }
        return cards
    }

    /// Demand is based on the user's configured cards, not the
    /// data-filtered `visibleCards`: Power/Battery must be allowed
    /// to collect their first sample before `hasData(_:)` can decide
    /// whether those cards are actually renderable on this machine.
    private var configuredDemandSlots: [CardTintSlot] {
        cardSettings.order().filter { cardSettings.visibility($0) }
    }

    /// Extra per-slot gating beyond the user's visibility flag.
    /// Battery needs an actual battery sample. Power needs at least
    /// one telemetry tick from the IOReport collector — when the
    /// libIOReport dylib is missing or the user is on a host that
    /// does not expose the Energy Model group, the collector emits
    /// nothing and we hide the card entirely instead of showing
    /// "0.0 W" rows forever.
    private func hasData(_ slot: CardTintSlot) -> Bool {
        switch slot {
        case .battery: store.latest(for: .batteryLevel) != nil
        case .power: store.latest(for: .powerPackage) != nil
        default: true
        }
    }

    /// Dispatches a slot to its concrete `*Card` view. This is the
    /// only place that knows the slot ↔ card-type mapping.
    @ViewBuilder
    private func cardView(
        for slot: CardTintSlot,
        batteryPresentation: BatteryCardPresentation = .standard,
    ) -> some View {
        switch slot {
        case .cpu: CPUCard()
        case .memory: MemoryCard()
        case .battery: BatteryCard(presentation: batteryPresentation)
        case .disk: DiskCard()
        case .network: NetworkCard()
        case .processes: ProcessesCard()
        case .gpu: GPUCard()
        case .power: PowerCard()
        }
    }

    /// Renders a single laid-out row. Half-card pairs are emitted as
    /// a `Grid` so both cells share the height of the taller cell;
    /// single rows stretch across the available width. In particular,
    /// a trailing half-width preference is promoted instead of leaving
    /// a blank 260 pt placeholder beside it. Battery is status-only at
    /// either width; a promoted row uses the shorter compact strip while
    /// a paired row keeps the shared card height without adding a chart.
    @ViewBuilder
    private func rowView(_ row: DashboardLayout.Row) -> some View {
        switch row {
        case let .single(card):
            cardView(
                for: card.slot,
                batteryPresentation: card.slot == .battery ? .compactStrip : .standard,
            )
            .environment(\.cardDensity, .full)
            .frame(maxWidth: .infinity, alignment: .leading)
        case let .pair(lhs, rhs):
            Grid(horizontalSpacing: 12, verticalSpacing: 0) {
                GridRow {
                    cardView(for: lhs.slot)
                        .environment(\.cardDensity, .half)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading,
                        )
                    cardView(for: rhs.slot)
                        .environment(\.cardDensity, .half)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading,
                        )
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "eye.slash")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("All cards hidden")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var header: some View {
        HStack(spacing: 8) {
            // Mirror the visual language of the bundle's app icon —
            // a circular gauge face with tick dots and a needle — by
            // picking the matching SF Symbol instead of rasterising
            // the icon asset.
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Peakmon")
                .font(.headline)
            Spacer()
            let warming = !store.hasHistory(for: .cpuTotal)
            Text(LocalizedStringKey(warming ? "Warming up…" : "Updated now"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                onShowHistory(issuesStore.recentEvents.first)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: issuesStore.recentEvents.isEmpty
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill")
                    if issuesStore.recentEvents.isEmpty {
                        Text("All clear")
                    } else if issuesStore.recentEvents.count == 1 {
                        Text("1 issue")
                    } else {
                        Text("\(issuesStore.recentEvents.count) issues")
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(popoverHealthTint)
            }
            .buttonStyle(.plain)
            .help("View health history")
        }
    }

    private var popoverHealthTint: Color {
        issuesStore.recentEvents.first?.severity.tint ?? .green
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                // v1.3 folded Settings into the unified main
                // window scene. Opening it here lands on
                // whatever `mainSelection` currently holds, which
                // defaults to `.dashboard` per the design — so
                // the popover's "open the full app" entry takes
                // the user to the dashboard surface on first use.
                openWindow(id: "main")
                ActivationPolicyController.shared.activateRegular()
            } label: {
                Image(systemName: "macwindow")
            }
            .accessibilityLabel("Open Peakmon")
            .help("Open Peakmon Window")

            Spacer(minLength: 12)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .accessibilityLabel("Quit Peakmon")
            .keyboardShortcut("q")
            .help("Quit Peakmon")
        }
        .buttonStyle(PopoverFooterIconButtonStyle())
    }
}

private struct PopoverFooterIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 26)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.08 : 0),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous),
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

private struct PopoverWindowVisibilityProbe: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = { isVisible = $0 }
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onChange = { isVisible = $0 }
        nsView.scheduleReport()
    }

    private final class ObserverBag: @unchecked Sendable {
        nonisolated(unsafe) var tokens: [NSObjectProtocol] = []

        nonisolated func removeAll(from center: NotificationCenter = .default) {
            tokens.forEach(center.removeObserver)
            tokens.removeAll()
        }
    }

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        private let observers = ObserverBag()
        private weak var observedWindow: NSWindow?
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installObservers()
            scheduleReport()
        }

        deinit {
            observers.removeAll()
        }

        func scheduleReport() {
            DispatchQueue.main.async { [weak self] in
                self?.report()
            }
        }

        private func installObservers() {
            guard observedWindow !== window else { return }

            let center = NotificationCenter.default
            observers.removeAll(from: center)
            observedWindow = window

            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.willCloseNotification,
            ]
            for name in names {
                observers.tokens.append(center.addObserver(
                    forName: name,
                    object: window,
                    queue: .main,
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.scheduleReport()
                    }
                })
            }
        }

        private func report() {
            let visible: Bool
            if let window {
                visible = window.isVisible && window.occlusionState.contains(.visible)
            } else {
                visible = false
            }
            guard visible != lastReported else { return }
            lastReported = visible
            onChange?(visible)
        }
    }
}
