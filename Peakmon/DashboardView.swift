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

import PeakmonCollectors
import PeakmonCore
import PeakmonUI
import SwiftUI

struct DashboardView: View {
    @Environment(MetricsStore.self) private var store
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

    /// Popover width, in points. Bumped from 300 → 420 to give two
    /// half-width cards enough horizontal room to render without
    /// truncating their multi-stat headers; full-width cards still
    /// look balanced at this width because the new padding-to-content
    /// ratio (14:392) is close to the original (14:272).
    static let popoverWidth: CGFloat = 420

    var body: some View {
        Group {
            if isVisible {
                visibleContent
            } else {
                // Fixed-size placeholder so the popover keeps the same
                // window geometry while hidden, and — critically — does
                // *not* read any `store.*` property so the @Observable
                // store no longer triggers `body` recomputes here.
                Color.clear.frame(width: Self.popoverWidth, height: 1)
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }

    /// Real popover content. Lives in its own computed property so the
    /// outer `body` does not even touch `store.*` while the popover is
    /// hidden — the SwiftUI dependency tracker then has nothing to
    /// invalidate on each `MetricsStore.ingest` tick.
    private var visibleContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            ForEach(Array(DashboardLayout.rows(from: visibleCards).enumerated()), id: \.offset) { _, row in
                rowView(row)
            }

            if visibleCards.isEmpty { emptyState }

            footer
        }
        .padding(14)
        .frame(width: Self.popoverWidth)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: visibilityKey)
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
                view: AnyView(cardView(for: slot)),
            ))
        }
        return cards
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
                    card.view
                        .environment(\.cardDensity, .half)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(maxWidth: .infinity)
                }
            } else {
                card.view
                    .environment(\.cardDensity, .full)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case let .pair(lhs, rhs):
            // Use a `Grid` for paired half-width cards so they
            // render at the same height and the same width. The
            // Grid row aligns every cell to a shared height (the
            // height of the tallest cell), which an ordinary
            // HStack(alignment: .top) does not do.
            Grid(horizontalSpacing: 12, verticalSpacing: 0) {
                GridRow {
                    lhs.view
                        .environment(\.cardDensity, .half)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading,
                        )
                    rhs.view
                        .environment(\.cardDensity, .half)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading,
                        )
                }
            }
            // Clamp the Grid's own height to the natural height of
            // its tallest cell so the equal-height behaviour does
            // not leak upward and inflate the popover's overall
            // height.
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Key that changes when any setting capable of mutating layout
    /// changes, so SwiftUI animates the transition.
    private var visibilityKey: String {
        let vis = CardTintSlot.allCases
            .map { "\(cardSettings.visibility($0))" }
            .joined()
        let wid = CardTintSlot.allCases
            .map(\.rawValue)
            .map { _ in "" }
            .joined()
        let widths = CardTintSlot.allCases
            .map { cardSettings.width($0).rawValue }
            .joined()
        let order = cardSettings.order().map(\.rawValue).joined(separator: ",")
        return vis + "|" + wid + widths + "|" + order
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "eye.slash")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("All cards hidden")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Enable cards in Settings › Display.")
                .font(.caption)
                .foregroundStyle(.tertiary)
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
            let warming = store.history(for: .cpuTotal).isEmpty
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

#Preview {
    CardSettingsScope {
        DashboardView()
    }
    .environment(MetricsStore())
    .environment(ProcessesStore())
}
