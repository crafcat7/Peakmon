//
//  SettingsView.swift
//  Peakmon
//
//  v1.0–v1.2 housed both the `SettingsCategory` enum and a
//  standalone `SettingsView` root that ran inside its own
//  `Window("settings")` scene. In v1.3 the dashboard and the
//  settings pages were folded into a single `Window("main")`
//  scene (see `MainWindow/`), so this file now only defines:
//
//    • `SettingsCategory`        — enum used by the main window
//                                   sidebar to label the SETTINGS
//                                   rows.
//    • `GeneralPage` / `DisplayPage` / `AboutPage`
//                                — page bodies. Promoted from
//                                   `private` to internal access so
//                                   `MainWindowView.detailContent`
//                                   can switch over them directly.
//
//  Everything else (the old `SettingsView` struct, its sidebar
//  helper, and the `SettingsView_Previews` block) was retired
//  when the scene moved into `MainWindow/`.
//

import PeakmonCore
import PeakmonUI
import ServiceManagement
import SwiftUI

// MARK: - Categories

enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case general
    case display

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .display: "Display"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        case .display: "paintpalette.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .blue
        case .display: .purple
        }
    }
}

// MARK: - General

struct GeneralPage: View {
    @AppStorage("samplingIntervalSeconds") private var samplingInterval: Double = 1.0
    @AppStorage("silentLaunch") private var silentLaunch = false
    @State private var loginController = LaunchAtLoginController()

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    var body: some View {
        SettingsPage(.general) {
            SettingsSection("Sampling", footer: "Lower intervals refresh data faster but use more CPU.") {
                HStack {
                    Text("Refresh every")
                    Spacer()
                    Picker("", selection: $samplingInterval) {
                        Text("0.5 s").tag(0.5)
                        Text("1 s").tag(1.0)
                        Text("2 s").tag(2.0)
                        Text("5 s").tag(5.0)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SettingsSection("Login") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Launch Peakmon at login")
                            Text(loginFootnote)
                                .font(.caption)
                                .foregroundStyle(loginController.requiresApproval ? .orange : .secondary)
                        }
                        Spacer()
                        if loginController.requiresApproval {
                            Button("Open Login Items") {
                                SMAppService.openSystemSettingsLoginItems()
                            }
                            .controlSize(.small)
                        }
                        Toggle("", isOn: Binding(
                            get: { loginController.isEnabled },
                            set: { loginController.setEnabled($0) },
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity)

                    if let lastError = loginController.lastError {
                        Text(lastError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Divider()

                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Silent launch")
                            Text("Skip opening the main window when Peakmon starts.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $silentLaunch)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            // About section absorbed from the former AboutPage as
            // part of the v1.3 D1 v3 settings restructure. Layout
            // mirrors the macOS "About this Mac" card: a centred
            // hero block (icon + name + version + tagline) over a
            // divider, with a single trailing row for project
            // links. The section title chrome from `SettingsSection`
            // is intentionally NOT used here — the centred hero
            // already announces what this block is, and an extra
            // "ABOUT" caption above it duplicates that.
            VStack(alignment: .leading, spacing: 8) {
                Text("About")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                VStack(spacing: 14) {
                    AppIconArtwork()
                        .frame(width: 88, height: 88)
                        .shadow(color: .blue.opacity(0.35), radius: 10, y: 4)
                        .padding(.top, 6)

                    VStack(spacing: 4) {
                        Text("Peakmon")
                            .font(.title2.weight(.semibold))
                        Text("Version \(version) · Build \(build)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Text("A focused, native macOS system monitor for your menu bar.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)

                    Divider()
                        .padding(.horizontal, 40)
                        .padding(.top, 4)

                    HStack(spacing: 14) {
                        Link(destination: URL(string: "https://github.com/crafcat7/Peakmon")!) {
                            Label("GitHub", systemImage: "link")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Link(destination: URL(string: "https://github.com/crafcat7/Peakmon/issues")!) {
                            Label("Report Issue", systemImage: "exclamationmark.bubble")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Text("© 2026 crafcat7")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .padding(.horizontal, 14)
                .background(.background.secondary, in: .rect(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.gray.opacity(0.18), lineWidth: 0.5)
                }
            }
        }
        .onAppear { loginController.refresh() }
    }

    /// Human-readable hint underneath the toggle. Surfaces the
    /// `requiresApproval` case from `SMAppService` so users know
    /// they need to act in System Settings → Login Items.
    private var loginFootnote: String {
        if loginController.requiresApproval {
            "Approval required in System Settings → Login Items."
        } else {
            "Start automatically after you sign in."
        }
    }
}

// MARK: - Display

struct DisplayPage: View {
    @Environment(MetricsStore.self) private var store
    @Environment(\.cardSettings) private var cardSettings
    @AppStorage(MenuBarComposition.storageKey)
    private var segmentsRaw = MenuBarComposition.encode(MenuBarComposition.defaultSegments)
    @AppStorage("processesSortByMemory") private var processesSortByMemory = false

    private var selectedSegments: [MenuBarSegment] {
        MenuBarComposition.decode(segmentsRaw)
    }

    private var availableSegments: [MenuBarSegment] {
        let selected = Set(selectedSegments)
        return MenuBarSegment.allCases.filter { !selected.contains($0) }
    }

    var body: some View {
        SettingsPage(.display) {
            // Menu Bar section absorbed from the former GeneralPage
            // as part of the v1.3 D1 v3 restructure. It lives on
            // the Display page because what it controls — the live
            // preview, the order of glyphs in the menu bar — is
            // fundamentally a *display* concern, not a runtime one.
            SettingsSection(
                "Menu Bar",
                footer: "Drag to reorder visible items. Tap to add or remove.",
            ) {
                VStack(alignment: .leading, spacing: 20) {
                    MenuBarLivePreview(segments: selectedSegments, store: store)

                    MenuBarSegmentList(
                        title: "Visible",
                        items: selectedSegments,
                        emptyHint: "No items selected — pick from below.",
                        reorderable: true,
                        onToggle: toggle,
                        onMove: moveBefore,
                    )

                    MenuBarSegmentList(
                        title: "Available",
                        items: availableSegments,
                        emptyHint: "All items are visible.",
                        reorderable: false,
                        onToggle: toggle,
                    )
                }
            }

            // Drag-and-drop reorder lives on lightweight thumbnail
            // tiles in the preview, not on the per-card config
            // sections. See `DisplayCardPreview.swift` for the
            // rationale.
            SettingsSection(
                "Card Layout",
                footer: "Drag a tile onto another tile to insert it there. Hidden cards stay visible here so you can pre-arrange them.",
            ) {
                DisplayCardPreview(
                    order: cardSettings.orderBinding(),
                    visibility: cardSettings.visibilityMap(),
                    widths: cardSettings.widthMap(),
                    tints: cardSettings.tintMap(),
                )
            }

            ForEach(cardSettings.order()) { slot in
                section(for: slot)
            }
        }
    }

    private func toggle(_ segment: MenuBarSegment) {
        var current = selectedSegments
        if let idx = current.firstIndex(of: segment) {
            current.remove(at: idx)
        } else {
            current.append(segment)
        }
        segmentsRaw = MenuBarComposition.encode(current)
    }

    private func moveBefore(source: MenuBarSegment, target: MenuBarSegment) {
        var current = selectedSegments
        guard let fromIndex = current.firstIndex(of: source) else { return }
        current.remove(at: fromIndex)
        guard let toIndex = current.firstIndex(of: target) else {
            current.append(source)
            segmentsRaw = MenuBarComposition.encode(current)
            return
        }
        current.insert(source, at: toIndex)
        segmentsRaw = MenuBarComposition.encode(current)
    }

    @ViewBuilder
    private func section(for slot: CardTintSlot) -> some View {
        if slot == .processes {
            processesSection
        } else {
            metricSection(.init(
                slot: slot,
                iconTint: cardSettings.tint(slot),
                isOn: cardSettings.visibilityBinding(slot),
                series: chartSeries(for: slot),
            ))
        }
    }

    /// Chart series that the per-card settings section should expose
    /// as toggleable rows. Cards without per-series controls (Memory,
    /// Battery, GPU) return an empty list.
    private func chartSeries(for slot: CardTintSlot) -> [ChartSeries] {
        switch slot {
        case .cpu: [.cpuTotal, .cpuUser, .cpuSystem]
        case .disk: [.diskRead, .diskWrite]
        case .network: [.netIn, .netOut]
        case .power: [.powerCPU, .powerGPU, .powerDRAM]
        case .memory, .battery, .gpu, .processes: []
        }
    }

    /// Top Processes block. Distinct from the regular metric sections
    /// because it has no chart series and adds a sort-order picker
    /// instead. Sampling for this card runs on a slower 2 s cadence
    /// because walking the BSD process table is ~50x more expensive
    /// than a host-statistics syscall — the footer makes that
    /// trade-off visible to the user.
    @ViewBuilder
    private var processesSection: some View {
        SettingsSection(
            "Top Processes",
            systemImage: "list.bullet.rectangle",
            iconTint: cardSettings.tint(.processes),
            footer: "Sampled every 2 seconds via libproc.",
        ) {
            VStack(spacing: 0) {
                MetricShowRow(
                    title: "Top Processes",
                    systemImage: "eye",
                    slot: .processes,
                    isOn: cardSettings.visibilityBinding(.processes),
                )
                Divider().padding(.vertical, 4)
                CardTintRow(slot: .processes, hideIcon: true)
                Divider().padding(.vertical, 4)
                CardWidthRow(slot: .processes)
                Divider().padding(.vertical, 4)
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up.arrow.down")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text("Sort by")
                    Spacer()
                    Picker("", selection: $processesSortByMemory) {
                        Text("CPU").tag(false)
                        Text("RAM").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
            }
        }
    }

    /// Renders one full metric block: header section containing
    /// `Show in dashboard`, `Tint`, and (when applicable) `Series`
    /// rows. Sections are titled by the metric name so each block
    /// reads as a self-contained unit. Slot-derived fields (title /
    /// system image) come straight from `CardTintSlot`.
    @ViewBuilder
    private func metricSection(_ config: MetricSectionConfig) -> some View {
        SettingsSection(
            config.slot.title,
            systemImage: config.slot.systemImage,
            iconTint: config.iconTint,
        ) {
            VStack(spacing: 0) {
                MetricShowRow(
                    title: config.slot.title,
                    systemImage: "eye",
                    slot: config.slot,
                    isOn: config.isOn,
                )
                Divider().padding(.vertical, 4)
                CardTintRow(slot: config.slot, hideIcon: true)
                Divider().padding(.vertical, 4)
                CardWidthRow(slot: config.slot)
                if !config.series.isEmpty {
                    Divider().padding(.vertical, 4)
                    ChartSeriesRow(series: config.series)
                }
            }
        }
    }
}

/// Bundles every value `metricSection(_:)` needs. `title` and
/// `systemImage` are no longer carried — both are derived from the
/// `slot`'s `CardTintSlot` properties.
private struct MetricSectionConfig {
    let slot: CardTintSlot
    let iconTint: Color
    let isOn: Binding<Bool>
    let series: [ChartSeries]
}

// MARK: - Menu bar preview + segment row

//
// See `MenuBarPreview.swift` for `MenuBarLivePreview` and
// `MenuBarSegmentRow`.

