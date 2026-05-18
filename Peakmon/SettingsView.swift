//
//  SettingsView.swift
//  Peakmon
//
//  Standalone Settings window. NavigationSplitView with three
//  categories: General (menu bar, sampling, login items), Display
//  (which cards & accent colors), and About. Animations are kept
//  spring-based and restrained.
//

import PeakmonCore
import PeakmonUI
import ServiceManagement
import SwiftUI

// MARK: - Categories

enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case general
    case display
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .display: "Display"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape.fill"
        case .display: "paintpalette.fill"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .blue
        case .display: .purple
        case .about: .gray
        }
    }
}

// MARK: - Root

struct SettingsView: View {
    @State private var selection: SettingsCategory = .general
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(200)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(NSColor.windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        // Suppress the implicit window title entirely so the title
        // bar stays clean — traffic-light buttons sit on a bare
        // toolbar with no left-aligned or capsule-wrapped label.
        .navigationTitle("")
        .frame(
            minWidth: 720,
            idealWidth: 820,
            maxWidth: .infinity,
            minHeight: 480,
            idealHeight: 560,
            maxHeight: .infinity,
        )
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsCategory.allCases) { category in
                SettingsSidebarRow(
                    category: category,
                    isSelected: category == selection,
                ) {
                    selection = category
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var detailContent: some View {
        ZStack {
            switch selection {
            case .general:
                GeneralPage()
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            case .display:
                DisplayPage()
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            case .about:
                AboutPage()
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: selection)
    }
}

// MARK: - General

private struct GeneralPage: View {
    @Environment(MetricsStore.self) private var store
    @AppStorage(MenuBarComposition.storageKey)
    private var segmentsRaw = MenuBarComposition.encode(MenuBarComposition.defaultSegments)
    @AppStorage("samplingIntervalSeconds") private var samplingInterval: Double = 1.0
    @AppStorage("silentLaunch") private var silentLaunch = false
    @State private var loginController = LaunchAtLoginController()

    private var selectedSegments: [MenuBarSegment] {
        MenuBarComposition.decode(segmentsRaw)
    }

    private var availableSegments: [MenuBarSegment] {
        let selected = Set(selectedSegments)
        return MenuBarSegment.allCases.filter { !selected.contains($0) }
    }

    var body: some View {
        SettingsPage(
            .general,
            subtitle: "Configure the menu bar appearance and runtime behaviour.",
        ) {
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
                            Text("Skip opening this Settings window when Peakmon starts.")
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

    private func toggle(_ segment: MenuBarSegment) {
        var current = selectedSegments
        if let idx = current.firstIndex(of: segment) {
            current.remove(at: idx)
        } else {
            // Append in user-chosen order; the persisted list is
            // free-form and gets reordered through the drag handle
            // in the Selected list above.
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
}

// MARK: - Display

private struct DisplayPage: View {
    @AppStorage("showCPUCard") private var showCPU = true
    @AppStorage("showMemoryCard") private var showMemory = true
    @AppStorage("showBatteryCard") private var showBattery = true
    @AppStorage("showDiskCard") private var showDisk = true
    @AppStorage("showNetworkCard") private var showNetwork = true

    @CardTintStorage(.cpu) private var cpuTint
    @CardTintStorage(.memory) private var memoryTint
    @CardTintStorage(.battery) private var batteryTint
    @CardTintStorage(.disk) private var diskTint
    @CardTintStorage(.network) private var networkTint

    var body: some View {
        SettingsPage(
            .display,
            subtitle: "Configure each metric card independently.",
        ) {
            metricSection(.init(
                title: "CPU",
                systemImage: "cpu",
                slot: .cpu,
                iconTint: cpuTint,
                isOn: $showCPU,
                series: [.cpuTotal, .cpuUser, .cpuSystem],
            ))
            metricSection(.init(
                title: "Memory",
                systemImage: "memorychip",
                slot: .memory,
                iconTint: memoryTint,
                isOn: $showMemory,
                series: [],
            ))
            metricSection(.init(
                title: "Battery",
                systemImage: "battery.100percent",
                slot: .battery,
                iconTint: batteryTint,
                isOn: $showBattery,
                series: [],
            ))
            metricSection(.init(
                title: "Disk",
                systemImage: "internaldrive",
                slot: .disk,
                iconTint: diskTint,
                isOn: $showDisk,
                series: [.diskRead, .diskWrite],
            ))
            metricSection(.init(
                title: "Network",
                systemImage: "network",
                slot: .network,
                iconTint: networkTint,
                isOn: $showNetwork,
                series: [.netIn, .netOut],
            ))
        }
    }

    /// Renders one full metric block: header section containing
    /// `Show in dashboard`, `Tint`, and (when applicable) `Series`
    /// rows. Sections are titled by the metric name so each block
    /// reads as a self-contained unit.
    @ViewBuilder
    private func metricSection(_ config: MetricSectionConfig) -> some View {
        SettingsSection(config.title, systemImage: config.systemImage, iconTint: config.iconTint) {
            VStack(spacing: 0) {
                MetricShowRow(
                    title: config.title,
                    systemImage: "eye",
                    slot: config.slot,
                    isOn: config.isOn,
                )
                Divider().padding(.vertical, 4)
                CardTintRow(slot: config.slot, hideIcon: true)
                if !config.series.isEmpty {
                    Divider().padding(.vertical, 4)
                    ChartSeriesRow(series: config.series)
                }
            }
        }
    }
}

/// Bundles every value `metricSection(_:)` needs so its parameter
/// list stays inside SwiftLint's `function_parameter_count` ceiling.
private struct MetricSectionConfig {
    let title: String
    let systemImage: String
    let slot: CardTintSlot
    let iconTint: Color
    let isOn: Binding<Bool>
    let series: [ChartSeries]
}

// MARK: - About

private struct AboutPage: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    var body: some View {
        SettingsPage(.about) {
            VStack(spacing: 16) {
                AppIconArtwork()
                    .frame(width: 88, height: 88)
                    .shadow(color: .blue.opacity(0.3), radius: 12, y: 4)
                    .padding(.top, 8)

                VStack(spacing: 4) {
                    Text("Peakmon")
                        .font(.title.weight(.semibold))
                    Text("Version \(version)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text("A focused, native macOS system monitor for your menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                HStack(spacing: 12) {
                    Link(destination: URL(string: "https://github.com/crafcat7/Peakmon")!) {
                        Label("GitHub", systemImage: "link")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }
}

// MARK: - Menu bar preview + segment row

//
// See `MenuBarPreview.swift` for `MenuBarLivePreview` and
// `MenuBarSegmentRow`.

#Preview {
    SettingsView()
        .environment(MetricsStore())
}
