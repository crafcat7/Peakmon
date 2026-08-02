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

    var subtitle: String {
        switch self {
        case .general: "Sampling, shortcuts, diagnostics, and startup behavior."
        case .display: "Choose what Peakmon shows and how cards are arranged."
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
    @AppStorage(HistoryIssueNotificationService.enabledKey) private var anomalyNotificationsEnabled = false
    @AppStorage(AppSurfacePreferences.menuBarEnabledKey) private var menuBarEnabled = true
    @AppStorage(AppSurfacePreferences.popoverEnabledKey) private var popoverEnabled = true
    @AppStorage(AppLanguage.storageKey) private var languageRawValue = AppLanguage.default.rawValue
    @State private var loginController = LaunchAtLoginController()

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    var body: some View {
        SettingsPage {
            SettingsOverviewRow {
                SettingsSection(
                    "Monitoring",
                    systemImage: "gauge.with.dots.needle.50percent",
                    iconTint: .blue,
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        settingsGroupLabel("SAMPLING")

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

                        Divider()

                        settingsGroupLabel("DIAGNOSTICS")

                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Anomaly notifications")
                                Text("Notify when History detects a new CPU, memory, power, thermal, disk, or network issue.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $anomalyNotificationsEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            } secondary: {
                SettingsSection(
                    "App Controls",
                    systemImage: "switch.2",
                    iconTint: .indigo,
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        settingsGroupLabel("SURFACES")

                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Menu Bar")
                                Text("Show live metrics in the macOS menu bar.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $menuBarEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .controlSize(.small)
                        }

                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Popover")
                                Text(popoverDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $popoverEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .controlSize(.small)
                                .disabled(!menuBarEnabled)
                        }

                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Language")
                                Text("Choose the language used by Peakmon.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("Language", selection: $languageRawValue) {
                                ForEach(AppLanguage.allCases) { language in
                                    Text(language.displayName).tag(language.rawValue)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }

                        Divider()

                        settingsGroupLabel("SHORTCUTS")

                        HStack(spacing: 10) {
                            Label("Show Dashboard", systemImage: "macwindow")
                            Spacer()
                            DashboardHotKeyRecorder()
                        }

                        HStack(spacing: 10) {
                            Label("Show Popover", systemImage: "rectangle.on.rectangle")
                            Spacer()
                            PopoverHotKeyRecorder()
                                .disabled(!menuBarEnabled || !popoverEnabled)
                                .opacity(menuBarEnabled && popoverEnabled ? 1 : 0.5)
                        }

                        Divider()

                        settingsGroupLabel("STARTUP")

                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Launch at login")
                                if let loginFootnote {
                                    Text(loginFootnote)
                                        .font(.caption)
                                        .foregroundStyle(loginController.requiresApproval ? .orange : .secondary)
                                }
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
                            Text("Silent launch")
                            Spacer()
                            Toggle("", isOn: $silentLaunch)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            } tertiary: {
                SettingsSection(
                    "About",
                    systemImage: "info.circle",
                    iconTint: .purple,
                ) {
                    VStack(spacing: 10) {
                        AppIconArtwork()
                            .frame(width: 88, height: 88)
                            .shadow(color: .purple.opacity(0.22), radius: 10, y: 4)

                        Text("Peakmon")
                            .font(.title3.weight(.semibold))

                        Text("Version \(version) · Build \(build)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)

                        Text("A focused, native macOS system monitor for your menu bar.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 6)

                        VStack(spacing: 8) {
                            Link(destination: URL(string: "https://github.com/crafcat7/Peakmon")!) {
                                Label("GitHub", systemImage: "link")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Link(destination: URL(string: "https://github.com/crafcat7/Peakmon/issues")!) {
                                Label("Report Issue", systemImage: "exclamationmark.bubble")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Text("© 2026 crafcat7")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .onAppear { loginController.refresh() }
        .onChange(of: menuBarEnabled) { _, enabled in
            if !enabled {
                popoverEnabled = false
            }
        }
        .onChange(of: anomalyNotificationsEnabled) { _, enabled in
            guard enabled else { return }
            Task {
                let granted = await HistoryIssueNotificationService.requestAuthorization()
                if !granted {
                    anomalyNotificationsEnabled = false
                }
            }
        }
    }

    private var popoverDescription: LocalizedStringKey {
        if !menuBarEnabled {
            "Enable the menu bar first; the popover needs it as an anchor."
        } else if popoverEnabled {
            "Show the compact metrics panel from the menu bar or its shortcut."
        } else {
            "Menu bar clicks open the full Dashboard instead."
        }
    }

    /// Hint underneath the toggle. Only surfaces the
    /// `requiresApproval` case from `SMAppService` so users know
    /// they need to act in System Settings → Login Items; the
    /// normal "what this toggle does" footnote is omitted since
    /// the toggle label is self-explanatory.
    private var loginFootnote: LocalizedStringKey? {
        if loginController.requiresApproval {
            "Approval required in System Settings → Login Items."
        } else {
            nil
        }
    }

    private func settingsGroupLabel(_ title: String) -> some View {
        Text(LocalizedStringKey(title))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.5)
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
        SettingsPage {
            // Menu Bar section absorbed from the former GeneralPage
            // as part of the v1.3 D1 v3 restructure. It lives on
            // the Display page because what it controls — the live
            // preview, the order of glyphs in the menu bar — is
            // fundamentally a *display* concern, not a runtime one.
            SettingsSection(
                "Menu Bar",
                systemImage: "menubar.rectangle",
                iconTint: .blue,
            ) {
                VStack(alignment: .leading, spacing: 20) {
                    MenuBarLivePreview(segments: selectedSegments, store: store)

                    MenuBarSegmentList(
                        title: "Visible",
                        items: selectedSegments,
                        emptyHint: nil,
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

            SettingsSection("Card Layout", systemImage: "rectangle.grid.2x2", iconTint: .purple) {
                DisplayCardPreview(
                    order: cardSettings.orderBinding(),
                    visibility: cardSettings.visibilityMap(),
                    tints: cardSettings.tintMap(),
                )
            }

            SettingsSection("Cards", systemImage: "slider.horizontal.3", iconTint: .indigo) {
                SettingsAdaptiveGrid(minimumColumnWidth: 330) {
                    ForEach(cardSettings.order()) { slot in
                        cardTile(for: slot)
                    }
                }
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
    private func cardTile(for slot: CardTintSlot) -> some View {
        if slot == .processes {
            processesTile
        } else {
            metricTile(.init(
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

    /// Top Processes tile. Distinct from the regular metric tiles
    /// because it has no chart series and adds a sort-order picker
    /// instead. Sampling for this card runs on a slower 2 s cadence
    /// because walking the BSD process table is ~50x more expensive
    /// than a host-statistics syscall — the footer makes that
    /// trade-off visible to the user.
    @ViewBuilder
    private var processesTile: some View {
        SettingsCardTile(
            title: "Top Processes",
            systemImage: "list.bullet.rectangle",
            tint: cardSettings.tint(.processes),
            isOn: cardSettings.visibilityBinding(.processes),
        ) {
            VStack(spacing: 0) {
                CardTintRow(slot: .processes, hideIcon: true)
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

                Text("Sampled every 2 seconds via libproc.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
        }
    }

    /// Renders one compact metric tile. Visibility is handled by the
    /// tile header; the body only contains tint and optional series.
    @ViewBuilder
    private func metricTile(_ config: MetricSectionConfig) -> some View {
        SettingsCardTile(
            title: config.slot.title,
            systemImage: config.slot.systemImage,
            tint: config.iconTint,
            isOn: config.isOn,
        ) {
            VStack(spacing: 0) {
                CardTintRow(slot: config.slot, hideIcon: true)
                if !config.series.isEmpty {
                    Divider().padding(.vertical, 4)
                    ChartSeriesRow(series: config.series)
                }
            }
        }
    }
}

/// Bundles every value `metricTile(_:)` needs. `title` and
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
