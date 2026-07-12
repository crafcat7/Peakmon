//
//  DashboardView.swift
//  Peakmon
//
//  v0.1 dashboard popover. Routes the user's per-card
//  visibility/width/order preferences into the row-packing layout
//  engine and dispatches each visible slot to the matching card
//  view. The card bodies themselves now live in their own files
//  (`CPUCard.swift`, `MemoryCard.swift`, …) so this view stays a
//  pure shell.
//

import AppKit
import PeakmonCore
import PeakmonUI
import SwiftUI

struct DashboardView: View {
    var visibilityOverride: Bool? = nil

    @Environment(MetricsStore.self) private var store
    @Environment(MetricsRuntime.self) private var runtime
    @Environment(\.cardSettings) private var cardSettings
    @Environment(\.openWindow) private var openWindow

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

    /// Popover width, in points. Bumped from 300 → 420 to give two
    /// half-width cards enough horizontal room to render without
    /// truncating their multi-stat headers; full-width cards still
    /// look balanced at this width because the new padding-to-content
    /// ratio (14:392) is close to the original (14:272).
    static let popoverWidth: CGFloat = 420
    static let popoverHeight: CGFloat = 900

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
        VStack(alignment: .leading, spacing: 12) {
            header

//            ScrollView {
//                LazyVStack(alignment: .leading, spacing: 12) {
//                    ForEach(DashboardLayout.rows(from: visibleCards), id: \.rowID) { row in
//                        rowView(row)
//                    }
//
//                    if visibleCards.isEmpty { emptyState }
//                }
//                .frame(maxWidth: .infinity, alignment: .topLeading)
//            }

            ForEach(DashboardLayout.rows(from: visibleCards), id: \.rowID) { row in
                rowView(row)
            }

            footer
        }
        .padding(14)
//        .frame(width: Self.popoverWidth, height: Self.popoverHeight, alignment: .topLeading)
        .frame(width: Self.popoverWidth)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    /// Materialises the user's visibility + width + order
    /// preferences into the ordered card list `DashboardLayout`
    /// packs into rows. Order is driven by `CardSettings.order()`
    /// so the popover reflects whatever sequence the user dragged
    /// into place on the Settings › Display preview.
    private var visibleCards: [DashboardLayout.VisibleCard] {
        var cards: [DashboardLayout.VisibleCard] = []
        for slot in cardSettings.order() where cardSettings.visibility(slot) && hasData(slot) {
            cards.append(.init(
                slot: slot,
                width: cardSettings.width(slot),
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
    private func cardView(for slot: CardTintSlot) -> some View {
        switch slot {
        case .cpu: CPUCard()
        case .memory: MemoryCard()
        case .battery: BatteryCard()
        case .disk: DiskCard()
        case .network: NetworkCard()
        case .processes: ProcessesCard()
        case .gpu: GPUCard()
        case .power: PowerCard()
        }
    }

    /// Renders a single laid-out row. Half-card pairs are emitted as
    /// a `Grid` so both cells share the height of the taller cell;
    /// single rows (full *or* half) get `.frame(maxWidth: .infinity,
    /// alignment: .leading)` so they stretch the full row.
    @ViewBuilder
    private func rowView(_ row: DashboardLayout.Row) -> some View {
        switch row {
        case let .single(card):
            if card.width == .half {
                HStack(spacing: 12) {
                    cardView(for: card.slot)
                        .environment(\.cardDensity, .half)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(maxWidth: .infinity)
                }
            } else {
                cardView(for: card.slot)
                    .environment(\.cardDensity, .full)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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

    /// Key that changes when any setting capable of mutating layout
    /// changes, so SwiftUI animates the transition.
    private var visibilityKey: String {
        let vis = CardTintSlot.allCases
            .map { "\(cardSettings.visibility($0))" }
            .joined()
        let widths = CardTintSlot.allCases
            .map { cardSettings.width($0).rawValue }
            .joined()
        let order = cardSettings.order().map(\.rawValue).joined(separator: ",")
        return vis + "|" + widths + "|" + order
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
            Text(warming ? "Warming up…" : "Live")
                .font(.caption)
                .foregroundStyle(warming ? Color.secondary : Color.green)
        }
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
                Label("Open Window", systemImage: "macwindow")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Open Peakmon Window")

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
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
