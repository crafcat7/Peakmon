//
//  PeakmonApp.swift
//  Peakmon
//
//  Menu bar entry point. v0.1 wires up MetricsStore + MetricsScheduler
//  with a single CPUCollector so the label and dashboard render live
//  data.
//

import AppKit
import Combine
import Foundation
import CoreGraphics
import ImageIO
import PeakmonCollectors
import PeakmonCore
import PeakmonUI
import SwiftUI

private final class PeakmonApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct PeakmonApp: App {
    @NSApplicationDelegateAdaptor(PeakmonApplicationDelegate.self) private var appDelegate

    @State private var store = MetricsStore(historyLimit: 120)
    @State private var processesStore = ProcessesStore()
    @State private var runtime = MetricsRuntime()
    @State private var menuBarStatusController: MenuBarStatusItemController?
    @State private var benchmarkStatusPopoverController: BenchmarkStatusPopoverController?
    @State private var didRunBenchmarkBootstrap = false
    /// Current page of the unified main window. Persists across
    /// window close/reopen during the running process so reopening
    /// via ⌘, returns the user to wherever they were last. Not
    /// `@AppStorage` because v1.3 anchors first-open on
    /// `MainWindowSelection.defaultLanding` (Dashboard) rather
    /// than restoring across launches.
    @State private var mainSelection: MainWindowSelection = .defaultLanding
    @Environment(\.openWindow) private var openWindow

    @AppStorage("silentLaunch") private var silentLaunch = false
    @AppStorage("samplingIntervalSeconds") private var samplingInterval: Double = 1.0
    @CardVisibilityStorage(.processes) private var showProcesses

    @SceneBuilder
    private var appScenes: some Scene {
        Window("Peakmon", id: "main") {
            CardSettingsScope(visibilityOverrides: benchmarkCardVisibilityOverrides) {
                if isBenchmarkWindowNeedsCompactDashboard {
                    DashboardView(visibilityOverride: true)
                        .environment(store)
                        .environment(processesStore)
                        .environment(runtime)
                } else {
                    MainWindowView(selection: $mainSelection)
                        .environment(store)
                        .environment(processesStore)
                        .environment(runtime)
                }
            }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1000, height: 680)
        // Hide the native title bar so the floating pill is the
        // only chrome at the top of the window. Window drag still
        // works on the empty area around the pill because hidden
        // title bars retain their hit-test region.
        .windowStyle(.hiddenTitleBar)
        .onChange(of: runtime.started, initial: true) { _, started in
            if !started {
                startRuntime()
                bootstrapIfNeeded()
            }
        }
        .onChange(of: samplingInterval) { _, newValue in
            runtime.updateInterval(seconds: newValue)
        }
        .onChange(of: showProcesses, initial: false) { _, newValue in
            runtime.processesEnabled = benchmarkProcessesVisibilityOverride ?? newValue
        }
    }

    @SceneBuilder
    var body: some Scene {
        appScenes
    }

    private func bootstrap() {
        ActivationPolicyController.shared.install()
        ActivationPolicyController.shared.refresh()
        MainWindowVisibility.shared.install()

        if isBenchmarkStatusPopoverBenchmarkEnabled {
            Task { @MainActor in
                let controller = BenchmarkStatusPopoverController(
                    store: store,
                    processesStore: processesStore,
                    runtime: runtime,
                    visibilityOverrides: benchmarkCardVisibilityOverrides,
                )
                benchmarkStatusPopoverController = controller
                controller.show()
                benchmarkLog("opened benchmark single status-item popover")
            }
            return
        }

        installMenuBarStatusItem()
        installDashboardHotKey()
        installPopoverHotKey()

        if isBenchmarkDashboardModeEnabled {
            Task { @MainActor in
                mainSelection = .defaultLanding
                openWindow(id: "main")
                ActivationPolicyController.shared.activateRegular()
                benchmarkLog("opened benchmark dashboard window")
            }
            return
        }

        if isBenchmarkPopoverModeEnabled {
            Task { @MainActor in
                let opened = await openMenuBarPopoverWindow()
                if opened {
                    benchmarkLog("opened menu bar popover window")
                } else if allowsBenchmarkPopoverFallback {
                    benchmarkLog("menu bar popover unavailable; opened explicit fallback window")
                    openWindow(id: "main")
                    ActivationPolicyController.shared.activateRegular()
                } else {
                    benchmarkLog("failed to open menu bar popover; pass --peakmon-benchmark-popover-fallback to measure the fallback DashboardView window")
                    NSApp.terminate(nil)
                }
            }
            return
        }

        if isBenchmarkMenubarOnlyModeEnabled {
            benchmarkLog("running benchmark menubar-only mode")
            return
        }

        if !silentLaunch {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                openWindow(id: "main")
                ActivationPolicyController.shared.activateRegular()
            }
        }
    }

    private func installMenuBarStatusItem() {
        guard menuBarStatusController == nil else {
            return
        }
        let controller = MenuBarStatusItemController(
            store: store,
            processesStore: processesStore,
            runtime: runtime,
            visibilityOverrides: benchmarkCardVisibilityOverrides,
        )
        menuBarStatusController = controller
        controller.start()
    }

    private func installDashboardHotKey() {
        DashboardHotKeyController.shared.start {
            Task { @MainActor in
                mainSelection = .dashboard
                openWindow(id: "main")
                ActivationPolicyController.shared.activateRegular()
                MainWindowVisibility.shared.recompute()
            }
        }
    }

    private func installPopoverHotKey() {
        DashboardHotKeyController.shared.startPopover {
            Task { @MainActor in
                menuBarStatusController?.togglePopoverFromHotKey()
            }
        }
    }

    private func bootstrapIfNeeded() {
        guard !didRunBenchmarkBootstrap else {
            return
        }
        didRunBenchmarkBootstrap = true
        bootstrap()
    }

    private func startRuntime() {
        let processesVisible = benchmarkProcessesVisibilityOverride ?? showProcesses
        runtime.start(
            store: store,
            processesStore: processesStore,
            interval: samplingInterval,
        )
        runtime.processesEnabled = processesVisible
    }

    private var isBenchmarkStatusPopoverOnlyModeEnabled: Bool {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--peakmon-benchmark-status-popover-only") {
            return true
        }
        if let flag = ProcessInfo.processInfo.environment["PEAKMON_BENCHMARK_STATUS_POPOVER_ONLY"] {
            let normalized = flag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["1", "true", "yes", "on"].contains(normalized)
        }
        return false
    }

    private var isBenchmarkWindowNeedsCompactDashboard: Bool {
        isBenchmarkPopoverModeEnabled || isBenchmarkStatusPopoverBenchmarkEnabled
    }

    private var isBenchmarkModeEnabled: Bool {
        isBenchmarkStatusPopoverBenchmarkEnabled || isBenchmarkDashboardModeEnabled || isBenchmarkPopoverModeEnabled
    }

    private var isBenchmarkStatusPopoverBenchmarkEnabled: Bool {
        isBenchmarkStatusPopoverModeEnabled || isBenchmarkStatusPopoverOnlyModeEnabled
    }

    private var isBenchmarkDashboardModeEnabled: Bool {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--peakmon-benchmark-dashboard") {
            return true
        }
        if let flag = ProcessInfo.processInfo.environment["PEAKMON_BENCHMARK_DASHBOARD"] {
            let normalized = flag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["1", "true", "yes", "on"].contains(normalized)
        }
        return false
    }

    private var isBenchmarkMenubarOnlyModeEnabled: Bool {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--peakmon-benchmark-menubar-only") {
            return true
        }
        if let flag = ProcessInfo.processInfo.environment["PEAKMON_BENCHMARK_MENUBAR_ONLY"] {
            let normalized = flag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["1", "true", "yes", "on"].contains(normalized)
        }
        return false
    }

    private var benchmarkCardVisibilityOverrides: [CardTintSlot: Bool] {
        if let processesVisible = benchmarkProcessesVisibilityOverride {
            return [.processes: processesVisible]
        }
        return [:]
    }

    private var benchmarkProcessesVisibilityOverride: Bool? {
        guard isBenchmarkModeEnabled else { return nil }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--peakmon-benchmark-processes-on") {
            return true
        }
        if args.contains("--peakmon-benchmark-processes-off") {
            return false
        }
        if let flag = ProcessInfo.processInfo.environment["PEAKMON_BENCHMARK_PROCESSES"] {
            let normalized = flag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["1", "true", "yes", "on"].contains(normalized) {
                return true
            }
            if ["0", "false", "no", "off"].contains(normalized) {
                return false
            }
        }
        return nil
    }

    private var isBenchmarkPopoverModeEnabled: Bool {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--peakmon-benchmark-popover") {
            return true
        }
        if let flag = ProcessInfo.processInfo.environment["PEAKMON_BENCHMARK_POPOVER"] {
            let normalized = flag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["1", "true", "yes", "on"].contains(normalized)
        }
        return false
    }

    private var isBenchmarkStatusPopoverModeEnabled: Bool {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--peakmon-benchmark-status-popover") {
            return true
        }
        if let flag = ProcessInfo.processInfo.environment["PEAKMON_BENCHMARK_STATUS_POPOVER"] {
            let normalized = flag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["1", "true", "yes", "on"].contains(normalized)
        }
        return false
    }

    private var allowsBenchmarkPopoverFallback: Bool {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--peakmon-benchmark-popover-fallback") {
            return true
        }
        if let flag = ProcessInfo.processInfo.environment["PEAKMON_BENCHMARK_POPOVER_FALLBACK"] {
            let normalized = flag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["1", "true", "yes", "on"].contains(normalized)
        }
        return false
    }

    private func benchmarkLog(_ message: String) {
        let line = "[PeakmonBenchmark] \(message)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    @MainActor
    private func openMenuBarPopoverWindow() async -> Bool {
        for _ in 0..<12 {
            if let window = preferredMenuBarExtraWindow() {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                if window.isVisible {
                    return true
                }
            }
            try? await Task.sleep(for: .milliseconds(75))
        }
        return false
    }

    @MainActor
    private func preferredMenuBarExtraWindow() -> NSWindow? {
        let candidates = NSApp.windows
            .filter(isLikelyMenuBarExtraWindow(_:))
            .sorted { lhs, rhs in
                lhs.level.rawValue > rhs.level.rawValue
            }

        if candidates.count == 1 { return candidates.first }
        return candidates
            .sorted { lhs, rhs in
                lhs.frame.width < rhs.frame.width
            }
            .first
    }

    private func isLikelyMenuBarExtraWindow(_ window: NSWindow) -> Bool {
        let className = String(describing: type(of: window))
        let likelyClass =
            className.contains("StatusBar") ||
            className.contains("NSPopover") ||
            className.contains("NSStatus")
        let isSmallFloat = window.frame.width < 900 && window.frame.height < 900
        let isHighLevel = window.level.rawValue >= NSWindow.Level.statusBar.rawValue
        let unnamed = window.title.isEmpty
        return (likelyClass || isHighLevel) && isSmallFloat && unnamed
    }
}

@MainActor
private final class BenchmarkStatusPopoverController {
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    init(
        store: MetricsStore,
        processesStore: ProcessesStore,
        runtime: MetricsRuntime,
        visibilityOverrides: [CardTintSlot: Bool],
    ) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Peakmon"
        statusItem.button?.toolTip = "Peakmon benchmark popover"
        statusItem.button?.setAccessibilityLabel("Peakmon benchmark popover")

        popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentSize = CGSize(width: DashboardView.popoverWidth, height: DashboardView.popoverHeight)
        popover.contentViewController = NSHostingController(rootView:
            CardSettingsScope(visibilityOverrides: visibilityOverrides) {
                DashboardView(visibilityOverride: true)
                    .environment(store)
                    .environment(processesStore)
                    .environment(runtime)
            }
        )
    }

    func show() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}

@MainActor
private final class MenuBarStatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let store: MetricsStore
    private let runtime: MetricsRuntime
    private var cache = MenuBarLabelCache()
    private var updateTimer: Timer?
    private var defaultsObserver: NSObjectProtocol?
    private var foregroundCancellable: AnyCancellable?

    init(
        store: MetricsStore,
        processesStore: ProcessesStore,
        runtime: MetricsRuntime,
        visibilityOverrides: [CardTintSlot: Bool],
    ) {
        self.store = store
        self.runtime = runtime
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = CGSize(width: DashboardView.popoverWidth, height: DashboardView.popoverHeight)
        popover.contentViewController = NSHostingController(rootView:
            CardSettingsScope(visibilityOverrides: visibilityOverrides) {
                DashboardView()
                    .environment(store)
                    .environment(processesStore)
                    .environment(runtime)
            }
        )

        super.init()

        popover.delegate = self
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "Peakmon"
            button.setAccessibilityLabel("Peakmon")
        }
    }

    deinit {
        updateTimer?.invalidate()
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    func start() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.renderStatusItem()
            }
        }
        updateTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.renderStatusItem(force: true)
            }
        }

        foregroundCancellable = StatusBarForeground.shared.$generation.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.renderStatusItem(force: true)
            }
        }

        renderStatusItem(force: true)
        scheduleStartupRender(after: .milliseconds(0))
        scheduleStartupRender(after: .milliseconds(80))
        scheduleStartupRender(after: .milliseconds(250))
        scheduleStartupRender(after: .milliseconds(700))
    }

    private func scheduleStartupRender(after delay: DispatchTimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor [weak self] in
                self?.renderStatusItem(force: true)
            }
        }
    }

    @objc
    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            scheduleStartupRender(after: .milliseconds(120))
        }
    }

    func togglePopoverFromHotKey() {
        guard let button = statusItem.button else { return }
        togglePopover(button)
    }

    func popoverWillShow(_ notification: Notification) {
        // DashboardView's visibility probe flips this after the
        // window is actually visible. Doing it here turns collectors
        // on during NSPopover.show and makes the open feel sticky.
    }

    func popoverDidClose(_ notification: Notification) {
        runtime.popoverVisible = false
        runtime.popoverNeedsProcesses = false
    }

    private func renderStatusItem(force: Bool = false) {
        let items = menuBarSegments()
        runtime.updateMenuBarSegments(items)

        let tints = menuBarTints()
        let palette = StatusBarForeground.shared.palette(statusButton: statusItem.button)
        let signature = MenuBarLabelSignature.make(
            store: store,
            items: items,
            tints: tints,
            usesLightText: palette.usesLightText,
            appearanceGeneration: palette.generation,
        )

        let image = cache.image(for: signature, force: force) {
            Self.renderImage(
                store: store,
                items: items,
                tints: tints,
                palette: palette,
            )
        }

        guard let button = statusItem.button else { return }
        guard let image else {
            button.image = nil
            button.title = "Peakmon"
            statusItem.length = NSStatusItem.variableLength
            return
        }

        image.isTemplate = false
        button.title = ""
        button.image = image
        button.imagePosition = .imageOnly
        statusItem.length = max(24, ceil(image.size.width) + 8)
    }

    private func menuBarSegments() -> [MenuBarSegment] {
        if let override = ProcessInfo.processInfo.environment["PEAKMON_BENCHMARK_MENU_SEGMENTS"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return MenuBarComposition.decode(override)
        }
        let raw = UserDefaults.standard.string(forKey: MenuBarComposition.storageKey)
            ?? MenuBarComposition.encode(MenuBarComposition.defaultSegments)
        return MenuBarComposition.decode(raw)
    }

    private func menuBarTints() -> [CardTintSlot: Color] {
        [
            .cpu: tint(for: .cpu),
            .memory: tint(for: .memory),
            .disk: tint(for: .disk),
            .network: tint(for: .network),
            .gpu: tint(for: .gpu),
            .power: tint(for: .power),
        ]
    }

    private func tint(for slot: CardTintSlot) -> Color {
        let hex = UserDefaults.standard.string(forKey: slot.storageKey) ?? slot.defaultHex
        return Color(hex: hex) ?? slot.defaultColor
    }

    private static func renderImage(
        store: MetricsStore,
        items: [MenuBarSegment],
        tints: [CardTintSlot: Color],
        palette: StatusBarPalette,
    ) -> NSImage? {
        guard !items.isEmpty else { return nil }

        let composed = HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, segment in
                if index > 0 {
                    Rectangle()
                        .fill(palette.divider)
                        .frame(width: 0.5, height: 16)
                }
                MenuBarSegmentBlock(
                    segment: segment,
                    store: store,
                    tints: tints,
                )
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(palette.foreground)
        .padding(.horizontal, 2)
        .frame(height: 22)
        .fixedSize()

        let renderer = ImageRenderer(content: composed)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage
        image?.isTemplate = false
        return image
    }
}

/// Holds the long-running `MetricsScheduler` so SwiftUI can keep it
/// alive across re-renders.
private struct SchedulerCadence: Equatable {
    let fast: Duration
    let medium: Duration
    let slow: Duration
}

private enum PowerAwareCadencePolicy {
    case normal
    case onBattery
    case lowPower
}

private enum CollectorDemand: String, CaseIterable, Hashable, Sendable {
    case cpu
    case memory
    case disk
    case network
    case gpu
    case power
    case thermal
    case fan
    case battery
}

@MainActor
@Observable
final class MetricsRuntime {
    private(set) var started = false
    private var fastScheduler: MetricsScheduler?
    private var mediumScheduler: MetricsScheduler?
    private var slowScheduler: MetricsScheduler?
    private var processTask: Task<Void, Never>?
    private var powerPolicyTask: Task<Void, Never>?
    private var metricsStore: MetricsStore?
    private var processesStore: ProcessesStore?
    private var processGateGeneration: UInt64 = 0
    private var requestedSamplingIntervalSeconds = 1.0
    private var appliedCadence: SchedulerCadence?
    private var menuBarSegments = MenuBarComposition.defaultSegments
    private var popoverConfiguredSlots: [CardTintSlot] = []
    private var activeCollectorDemand: Set<CollectorDemand> = []
    private var collectorDemandGeneration: UInt64 = 0
    private let collectorDemandGate = CollectorDemandGate()
    private let demandGatingDisabled = MetricsRuntime.isDemandGatingDisabled()

    /// True while the popover dashboard is actually on-screen. When
    /// false and the main dashboard is also hidden, the runtime keeps
    /// the menu-bar label fresh at a lower cadence instead of polling
    /// every collector at full dashboard speed.
    var popoverVisible = false {
        didSet {
            updateCollectorDemand()
        }
    }

    /// True while the main dashboard surface is worth painting. This
    /// tracks visibility, not merely whether the Window scene exists.
    var mainDashboardVisible = false {
        didSet {
            updateCollectorDemand()
        }
    }

    /// User preference for the heavy Processes card. The runtime only
    /// walks libproc when this is true *and* a visible surface is
    /// currently reading process data.
    var processesEnabled = false {
        didSet {
            updateProcessGate()
        }
    }

    /// True while the menu-bar popover is visible and includes the
    /// Processes card.
    var popoverNeedsProcesses = false {
        didSet {
            updateProcessGate()
        }
    }

    /// True while the main dashboard window is visible and includes
    /// the full-width Processes panel.
    var mainDashboardNeedsProcesses = false {
        didSet {
            updateProcessGate()
        }
    }

    /// Cadence at which the process collector polls libproc, in
    /// seconds. Kept slower than the host-metric scheduler because
    /// walking ~500 PIDs is ~50x more expensive than a single
    /// `host_statistics64` call. 2 s matches Activity Monitor's
    /// default refresh and is plenty for trend spotting.
    private static let processInterval: Duration = .seconds(2)
    private let processCollector = ProcessCollectorGate(collector: ProcessCollector())

    func updateMenuBarSegments(_ segments: [MenuBarSegment]) {
        guard segments != menuBarSegments else { return }
        menuBarSegments = segments
        updateCollectorDemand()
    }

    func updatePopoverConfiguredSlots(_ slots: [CardTintSlot]) {
        guard slots != popoverConfiguredSlots else { return }
        popoverConfiguredSlots = slots
        updateCollectorDemand()
    }

    func start(
        store: MetricsStore,
        processesStore: ProcessesStore,
        interval: Double,
    ) {
        guard !started else { return }
        started = true
        metricsStore = store
        self.processesStore = processesStore
        requestedSamplingIntervalSeconds = interval
        let cadence = effectiveCadence()
        let fastScheduler = MetricsScheduler(
            store: store,
            collectors: [
                DemandGatedCollector(demand: .cpu, collector: CPUCollector(), gate: collectorDemandGate),
                DemandGatedCollector(demand: .memory, collector: MemoryCollector(), gate: collectorDemandGate),
                DemandGatedCollector(demand: .disk, collector: DiskCollector(), gate: collectorDemandGate),
                DemandGatedCollector(demand: .network, collector: NetworkCollector(), gate: collectorDemandGate),
            ],
            interval: cadence.fast,
        )
        let mediumScheduler = MetricsScheduler(
            store: store,
            collectors: [
                DemandGatedCollector(demand: .gpu, collector: GPUCollector(), gate: collectorDemandGate),
                DemandGatedCollector(demand: .power, collector: PowerCollector(), gate: collectorDemandGate),
                DemandGatedCollector(demand: .power, collector: SystemPowerCollector(), gate: collectorDemandGate),
                DemandGatedCollector(demand: .thermal, collector: ThermalCollector(), gate: collectorDemandGate),
                DemandGatedCollector(demand: .fan, collector: FanCollector(), gate: collectorDemandGate),
            ],
            interval: cadence.medium,
        )
        let slowScheduler = MetricsScheduler(
            store: store,
            collectors: [
                DemandGatedCollector(demand: .battery, collector: BatteryCollector(), gate: collectorDemandGate),
            ],
            interval: cadence.slow,
        )
        self.fastScheduler = fastScheduler
        self.mediumScheduler = mediumScheduler
        self.slowScheduler = slowScheduler
        appliedCadence = cadence
        Task { await fastScheduler.start() }
        Task { await mediumScheduler.start() }
        Task { await slowScheduler.start() }
        updateCollectorDemand()
        spawnProcessLoop(processesStore: processesStore)
        spawnPowerPolicyLoop()
    }

    /// Pushes a new sampling cadence into the running scheduler.
    /// Called from the SwiftUI scene whenever the user changes the
    /// `samplingIntervalSeconds` AppStorage value.
    func updateInterval(seconds: Double) {
        requestedSamplingIntervalSeconds = seconds
        updateCollectorDemand()
    }

    private func updateCollectorDemand() {
        let demands = effectiveCollectorDemand()
        let demandChanged = demands != activeCollectorDemand
        if demandChanged {
            activeCollectorDemand = demands
        }

        let cadence = effectiveCadence()
        let cadenceChanged = cadence != appliedCadence
        guard demandChanged || cadenceChanged else { return }
        let gate = collectorDemandGate
        collectorDemandGeneration &+= 1
        let generation = collectorDemandGeneration
        appliedCadence = cadence

        Task {
            if demandChanged {
                let didApplyGate = await gate.setActive(demands, generation: generation)
                guard didApplyGate else { return }
            }
            guard isCurrentCollectorDemandGeneration(generation) else { return }
            await updateSchedulers(to: cadence)
        }
    }

    private func isCurrentCollectorDemandGeneration(_ generation: UInt64) -> Bool {
        generation == collectorDemandGeneration
    }

    private func updateSchedulers(to cadence: SchedulerCadence) async {
        if let fastScheduler {
            await fastScheduler.updateInterval(cadence.fast)
        }
        if let mediumScheduler {
            await mediumScheduler.updateInterval(cadence.medium)
        }
        if let slowScheduler {
            await slowScheduler.updateInterval(cadence.slow)
        }
    }

    private func effectiveCollectorDemand() -> Set<CollectorDemand> {
        if demandGatingDisabled {
            return Set(CollectorDemand.allCases)
        }

        var demands = Set<CollectorDemand>()

        for segment in menuBarSegments {
            demands.formUnion(segment.collectorDemands)
        }

        if popoverVisible {
            for slot in popoverConfiguredSlots {
                demands.formUnion(slot.popoverCollectorDemands)
            }
        }

        if mainDashboardVisible {
            // The main dashboard currently renders CPU, Memory, GPU,
            // Power, Disk, and Network unconditionally. CPU/GPU need
            // thermal samples; GPU and Power need IOReport power;
            // Power folds in Battery state.
            demands.formUnion([.cpu, .memory, .disk, .network, .gpu, .power, .thermal, .battery])
        }

        if !popoverVisible && !mainDashboardVisible {
            // Keep a low-frequency battery sample alive in the
            // background so power-aware cadence can react to AC /
            // battery / low-battery state without waiting for the
            // user to display a battery card or menu segment.
            demands.insert(.battery)
        }

        return demands
    }

    private func effectiveCadence() -> SchedulerCadence {
        let detailedSurfaceVisible = popoverVisible || mainDashboardVisible
        let hasFastDemand = !activeCollectorDemand.isDisjoint(with: [.cpu, .memory, .disk, .network])
        let hasMediumDemand = !activeCollectorDemand.isDisjoint(with: [.gpu, .power, .thermal, .fan])
        let hasSlowDemand = activeCollectorDemand.contains(.battery)
        let backgroundPolicy = detailedSurfaceVisible ? .normal : powerAwareCadencePolicy()
        let backgroundFastMinimum: Double
        let backgroundMediumMinimum: Double
        let backgroundSlowMinimum: Double
        switch backgroundPolicy {
        case .normal:
            backgroundFastMinimum = 2
            backgroundMediumMinimum = hasMediumDemand ? 5 : 60
            backgroundSlowMinimum = hasSlowDemand ? 30 : 300
        case .onBattery:
            backgroundFastMinimum = 3
            backgroundMediumMinimum = hasMediumDemand ? 10 : 60
            backgroundSlowMinimum = hasSlowDemand ? 60 : 300
        case .lowPower:
            backgroundFastMinimum = 5
            backgroundMediumMinimum = hasMediumDemand ? 15 : 60
            backgroundSlowMinimum = hasSlowDemand ? 120 : 300
        }
        let fastMinimum = hasFastDemand
            ? (detailedSurfaceVisible ? 0.05 : backgroundFastMinimum)
            : 60
        return SchedulerCadence(
            fast: Self.duration(
                seconds: requestedSamplingIntervalSeconds,
                minimum: fastMinimum,
            ),
            medium: Self.duration(
                seconds: requestedSamplingIntervalSeconds,
                minimum: detailedSurfaceVisible ? (hasMediumDemand ? 2 : 60) : backgroundMediumMinimum,
            ),
            slow: Self.duration(
                seconds: requestedSamplingIntervalSeconds,
                minimum: detailedSurfaceVisible ? (hasSlowDemand ? 10 : 300) : backgroundSlowMinimum,
            ),
        )
    }

    private func powerAwareCadencePolicy() -> PowerAwareCadencePolicy {
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return .lowPower
        }

        guard
            let metricsStore,
            let sourceSample = metricsStore.latest(for: .batteryPowerSource)
        else {
            return .normal
        }

        let source = BatteryPowerSource(metricValue: sourceSample.value)
        guard source == .onBattery else { return .normal }

        let level = metricsStore.latest(for: .batteryLevel)?.value
        if let level, level <= 20 {
            return .lowPower
        }
        return .onBattery
    }

    private static func duration(seconds: Double, minimum: Double = 0.05) -> Duration {
        // `Duration.seconds(_:)` only accepts integers when used with
        // a `Double` literal needs `.milliseconds` to keep sub-second
        // precision (e.g. 0.5 s -> 500 ms).
        let clamped = max(minimum, seconds)
        let millis = Int((clamped * 1000).rounded())
        return .milliseconds(max(50, millis))
    }

    private static func isDemandGatingDisabled() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--peakmon-disable-demand-gating") {
            return true
        }
        if let flag = ProcessInfo.processInfo.environment["PEAKMON_DISABLE_DEMAND_GATING"] {
            let normalized = flag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["1", "true", "yes", "on"].contains(normalized)
        }
        return false
    }

    private func updateProcessGate() {
        let shouldCollect = processesEnabled
            && (popoverNeedsProcesses || mainDashboardNeedsProcesses)
        processGateGeneration &+= 1
        let generation = processGateGeneration
        let gate = processCollector
        let processesStore = processesStore
        Task {
            let transition = await gate.setEnabled(shouldCollect, generation: generation)
            switch transition {
            case .enabled:
                break
            case .disabled:
                await MainActor.run {
                    processesStore?.clear()
                }
                return
            case .unchanged:
                return
            }

            guard let processesStore else { return }

            // Seed a fresh baseline immediately, then publish the
            // first real diff one second later instead of waiting for
            // the detached 2 s polling loop to line up twice.
            _ = try? await gate.collect()
            try? await Task.sleep(for: .seconds(1))
            if let snapshots = try? await gate.collect() {
                await MainActor.run {
                    processesStore.ingest(snapshots)
                }
            }
        }
    }

    /// Long-running task that polls `ProcessCollector` on the slower
    /// fixed cadence. Cancellation happens implicitly when the
    /// runtime is deallocated; the task observes `Task.isCancelled`
    /// and returns cleanly.
    private func spawnProcessLoop(processesStore: ProcessesStore) {
        let gate = processCollector
        processTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                do {
                    if let snapshots = try await gate.collect() {
                        await MainActor.run {
                            processesStore.ingest(snapshots)
                        }
                    }
                } catch {
                    // Process enumeration is best-effort; failures are
                    // dropped silently so a single bad tick doesn't
                    // tear the loop down.
                }
                do {
                    try await Task.sleep(for: Self.processInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func spawnPowerPolicyLoop() {
        powerPolicyTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
                self?.updateCollectorDemand()
            }
        }
    }
}

/// Wrapper around `ProcessCollector` that gates expensive libproc
/// walks on a user-controllable enabled flag. When disabled, the
/// gate returns an empty list once (to clear stale data in the
/// store) and then `nil` to short-circuit subsequent polls without
/// any work. Re-enabling resets the gate so collection resumes
/// immediately on the next tick.
///
/// Implemented as an actor so the `enabled` / `didFlushAfterDisable`
/// state stays safe across the SwiftUI MainActor caller (toggle from
/// the settings page) and the detached background loop (long poll
/// every 2 s).
private actor ProcessCollectorGate {
    private let collector: ProcessCollector
    private var enabled = false
    private var didFlushAfterDisable = true
    private var latestGeneration: UInt64 = 0

    init(collector: ProcessCollector) {
        self.collector = collector
    }

    @discardableResult
    func setEnabled(_ value: Bool, generation: UInt64) async -> ProcessCollectorGateTransition {
        guard generation >= latestGeneration else { return .unchanged }
        latestGeneration = generation
        if value == enabled { return .unchanged }
        enabled = value
        // After flipping off, push one empty snapshot so the UI
        // forgets stale rows. After flipping on, reset the collector
        // baseline so the first real diff reflects the visible
        // interval rather than time spent hidden.
        didFlushAfterDisable = false
        if value {
            await collector.reset()
            return .enabled
        }
        return .disabled
    }

    /// Returns:
    ///   - the latest snapshot list when collection is active
    ///   - `[]` exactly once after the collector was disabled, so the
    ///     consumer can clear stale data
    ///   - `nil` afterwards while still disabled, signalling "no
    ///     update needed"
    func collect() async throws -> [ProcessSnapshot]? {
        let isEnabled = enabled
        let needsFlush = !didFlushAfterDisable
        if needsFlush { didFlushAfterDisable = true }

        if !isEnabled {
            return needsFlush ? [] : nil
        }
        return try await collector.collect()
    }
}

private enum ProcessCollectorGateTransition: Sendable {
    case unchanged
    case enabled
    case disabled
}

/// Lightweight demand switch for hardware-facing collectors. The
/// scheduler still wakes at its current cadence, but inactive
/// collectors return before touching IOReport / SMC / IOKit.
private actor CollectorDemandGate {
    private var active: Set<CollectorDemand> = []
    private var activationEpochs: [CollectorDemand: UInt64] = [:]
    private var latestGeneration: UInt64 = 0

    @discardableResult
    func setActive(_ demands: Set<CollectorDemand>, generation: UInt64) -> Bool {
        guard generation >= latestGeneration else { return false }
        latestGeneration = generation
        for demand in demands where !active.contains(demand) {
            activationEpochs[demand, default: 0] &+= 1
        }
        active = demands
        return true
    }

    func state(for demand: CollectorDemand) -> CollectorDemandState {
        CollectorDemandState(
            isActive: active.contains(demand),
            activationEpoch: activationEpochs[demand] ?? 0,
        )
    }
}

private struct DemandGatedCollector<Wrapped: MetricCollector>: MetricCollector {
    let demand: CollectorDemand
    let collector: Wrapped
    let gate: CollectorDemandGate
    private let state = DemandGatedCollectorState()

    var identifier: String {
        "\(collector.identifier).demand.\(demand.rawValue)"
    }

    func collect() async throws -> [MetricSample] {
        let demandState = await gate.state(for: demand)
        guard demandState.isActive else { return [] }

        let reset: (@Sendable () async -> Void)?
        if let resettable = collector as? any ResettableMetricCollector {
            reset = {
                await resettable.reset()
            }
        } else {
            reset = nil
        }

        let task = await state.enqueueCollect(
            activationEpoch: demandState.activationEpoch,
            reset: reset,
            collect: {
                try await collector.collect()
            },
        )
        return try await task.value
    }
}

private struct CollectorDemandState: Sendable {
    let isActive: Bool
    let activationEpoch: UInt64
}

private actor DemandGatedCollectorState {
    private var lastActiveEpoch: UInt64?
    private var tail: Task<Void, Never>?

    func enqueueCollect(
        activationEpoch: UInt64,
        reset: (@Sendable () async -> Void)?,
        collect: @escaping @Sendable () async throws -> [MetricSample],
    ) -> Task<[MetricSample], Error> {
        if let lastActiveEpoch, activationEpoch < lastActiveEpoch {
            return Task { [] }
        }

        let shouldReset = lastActiveEpoch.map { $0 != activationEpoch } ?? false
        lastActiveEpoch = activationEpoch

        let predecessor = tail
        let task = Task<[MetricSample], Error> {
            await predecessor?.value
            if shouldReset, let reset {
                await reset()
            }
            return try await collect()
        }
        tail = Task {
            _ = try? await task.value
        }
        return task
    }
}

private extension MenuBarSegment {
    var collectorDemands: Set<CollectorDemand> {
        switch self {
        case .cpuPercent, .cpuGraph:
            [.cpu]
        case .gpuPercent, .gpuGraph:
            [.gpu]
        case .memoryPercent, .memoryGraph:
            [.memory]
        case .networkRate, .networkGraph:
            [.network]
        case .diskRate, .diskGraph:
            [.disk]
        case .powerWatts, .powerGraph:
            [.power]
        case .batteryPercent:
            [.battery]
        }
    }
}

private extension CardTintSlot {
    var popoverCollectorDemands: Set<CollectorDemand> {
        switch self {
        case .cpu:
            [.cpu, .thermal]
        case .gpu:
            [.gpu, .thermal]
        case .battery:
            [.battery]
        case .power:
            [.power, .fan, .battery]
        case .memory:
            [.memory]
        case .disk:
            [.disk]
        case .network:
            [.network]
        case .processes:
            []
        }
    }
}

/// Menu bar title view that composes the selected `MenuBarSegment`
/// list (persisted via `@AppStorage`) into a `|`-separated label.
///
/// `MenuBarExtra` only honours `Text` and `Image` in its label, so the
/// composed SwiftUI view is rasterised through `ImageRenderer` and
/// emitted as a single `Image(nsImage:)` to guarantee both the bar
/// charts and the multi-segment layout reach the status bar intact.
private struct MenuBarLabel: View {
    let store: MetricsStore
    let runtime: MetricsRuntime

    @AppStorage(MenuBarComposition.storageKey)
    private var segmentsRaw = MenuBarComposition.encode(MenuBarComposition.defaultSegments)
    @CardTintStorage(.cpu) private var cpuTint
    @CardTintStorage(.memory) private var memoryTint
    @CardTintStorage(.disk) private var diskTint
    @CardTintStorage(.network) private var networkTint
    @CardTintStorage(.gpu) private var gpuTint
    @CardTintStorage(.power) private var powerTint

    /// Snapshot of the 6 tints that menu-bar graph segments may
    /// reference. Materialised lazily so the property wrappers above
    /// stay the single source of truth.
    private var tints: [CardTintSlot: Color] {
        [
            .cpu: cpuTint, .memory: memoryTint, .disk: diskTint,
            .network: networkTint, .gpu: gpuTint, .power: powerTint,
        ]
    }

    /// Cached rasterised label. Recomputed only when the source data
    /// actually changes, so the menu-bar refresh loop costs ~0 % CPU
    /// when metrics are stable. Boxed in a reference type so the body
    /// getter can mutate it without violating SwiftUI's pure-body rule.
    @State private var cache = MenuBarLabelCache()
    @ObservedObject private var foreground = StatusBarForeground.shared

    private var segments: [MenuBarSegment] {
        if let override = ProcessInfo.processInfo.environment["PEAKMON_BENCHMARK_MENU_SEGMENTS"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return MenuBarComposition.decode(override)
        }
        return MenuBarComposition.decode(segmentsRaw)
    }

    var body: some View {
        let items = segments
        let tints = self.tints
        let palette = foreground.palette()
        let signature = MenuBarLabelSignature.make(
            store: store,
            items: items,
            tints: tints,
            usesLightText: palette.usesLightText,
            appearanceGeneration: palette.generation,
        )
        let image = cache.image(for: signature) {
            render(items: items, tints: tints, palette: palette)
        }

        return Group {
            if let image {
                Image(nsImage: image)
                    .renderingMode(.original)
                    .interpolation(.high)
            } else {
                Text("Peakmon")
            }
        }
        .onChange(of: items, initial: true) { _, newValue in
            runtime.updateMenuBarSegments(newValue)
        }
    }

    @MainActor
    private func render(
        items: [MenuBarSegment],
        tints: [CardTintSlot: Color],
        palette: StatusBarPalette,
    ) -> NSImage? {
        guard !items.isEmpty else { return nil }

        let composed = HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, segment in
                if index > 0 {
                    Rectangle()
                        .fill(palette.divider)
                        .frame(width: 0.5, height: 16)
                }
                MenuBarSegmentBlock(
                    segment: segment,
                    store: store,
                    tints: tints,
                )
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(palette.foreground)
        .padding(.horizontal, 2)
        .frame(height: 22)
        .fixedSize()

        let renderer = ImageRenderer(content: composed)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage
        image?.isTemplate = false
        return image
    }
}

/// Reference-typed cache for the rasterised menu-bar label. Kept in a
/// `class` so the SwiftUI body can read and update the cache in-place
/// without violating the "pure body" rule (`@State` value mutation
/// would trigger a runtime warning).
@MainActor
private final class MenuBarLabelCache {
    private var renderedSignature: MenuBarLabelSignature?
    private var renderedAt: Date?
    private var image: NSImage?
    private let minimumMetricRenderInterval: TimeInterval = 1.0

    func image(
        for signature: MenuBarLabelSignature,
        force: Bool = false,
        render: () -> NSImage?,
    ) -> NSImage? {
        if !force, let cached = renderedSignature, cached == signature, let image {
            return image
        }
        let now = Date.now
        if !force,
           let cached = renderedSignature,
           let renderedAt,
           let image,
           cached.hasSameVisualConfiguration(as: signature),
           now.timeIntervalSince(renderedAt) < minimumMetricRenderInterval
        {
            return image
        }
        let newImage = render()
        renderedSignature = signature
        self.renderedAt = now
        image = newImage
        return newImage
    }
}

/// Compact, value-equatable fingerprint of every input that affects the
/// rasterised menu-bar label. When two signatures match, the previously
/// cached `NSImage` can be reused without re-running the SwiftUI
/// renderer.
private struct MenuBarLabelSignature: Equatable {
    let segments: [MenuBarSegment]
    let usesLightText: Bool
    let appearanceGeneration: Int
    let tints: [String]      // [cpu, memory, disk, network, gpu, power] hex
    let latestValues: [Double]
    let historyHashes: [Int]

    func hasSameVisualConfiguration(as other: Self) -> Bool {
        segments == other.segments
            && usesLightText == other.usesLightText
            && appearanceGeneration == other.appearanceGeneration
            && tints == other.tints
    }

    @MainActor
    static func make(
        store: MetricsStore,
        items: [MenuBarSegment],
        tints: [CardTintSlot: Color],
        usesLightText: Bool,
        appearanceGeneration: Int,
    ) -> Self {
        var latests: [Double] = []
        var historyHashes: [Int] = []
        for segment in items {
            for input in segment.template.value.signatureInputs {
                switch input {
                case let .percent(kind):
                    latests.append(Self.round(store.latest(for: kind)?.value))
                case let .rate(kind):
                    latests.append(Self.bucketRate(store.latest(for: kind)?.value))
                case let .history(kind):
                    historyHashes.append(
                        Self.hashHistory(
                            store.historySuffix(for: kind, limit: SegmentMetrics.miniChartBarCount),
                            step: 1,
                        ),
                    )
                case let .rateHistory(kind):
                    historyHashes.append(
                        Self.hashRateHistory(
                            store.historySuffix(for: kind, limit: SegmentMetrics.miniChartBarCount),
                        ),
                    )
                case let .raw(kind):
                    latests.append(store.latest(for: kind)?.value ?? -1)
                case let .watts(kind):
                    latests.append(Self.bucketWatts(store.latest(for: kind)?.value))
                }
            }
        }

        // Stable ordering by `CardTintSlot.allCases` so signature
        // equality compares apples to apples across calls. The 2
        // dashboard-only slots (battery/processes) are absent from
        // `tints` and serialise as empty strings, which is fine: their
        // absence is itself constant for menu-bar rendering.
        let tintHexes = CardTintSlot.allCases.map { tints[$0]?.hexString ?? "" }

        return MenuBarLabelSignature(
            segments: items,
            usesLightText: usesLightText,
            appearanceGeneration: appearanceGeneration,
            tints: tintHexes,
            latestValues: latests,
            historyHashes: historyHashes,
        )
    }

    /// Quantises a metric value so 0.001-level jitter does not force a
    /// re-render. `step = 1` keeps integer percent precision.
    private static func round(_ value: Double?, _ step: Double = 1) -> Double {
        guard let value else { return -1 }
        return (value / step).rounded()
    }

    /// Quantises a byte/second rate to the granularity that
    /// `MenuBarSegmentBlock.shortRate` actually displays:
    ///   - <1 KiB/s   -> bucket 0     ("  0K")
    ///   - <1000 KiB/s-> KiB integer  (" 12K")
    ///   - <10 MiB/s  -> 0.1 MiB      ("1.2M")
    ///   - <1000 MiB/s-> MiB integer  (" 12M")
    ///   - >=1000 MiB -> 0.1 GiB      ("1.2G")
    /// Anything inside the same display bucket maps to the same key
    /// and reuses the cached rasterised label.
    ///
    /// CRITICAL: this MUST use the *exact same* truncation as
    /// `shortRate` — `Int(x)` truncates toward zero (we mirror that
    /// with `.rounded(.down)` for non-negative input) and replicate
    /// the *exact* branch boundaries used in `shortRate`. Mixing
    /// rounding modes would let two `value`s that render to
    /// different strings collide on the cache key.
    private static func bucketRate(_ value: Double?) -> Double {
        guard let value, value > 0 else { return 0 }
        let kib = value / 1024
        if kib < 1 { return 0 }
        if kib < 1000 { return kib.rounded(.down) }
        let mib = kib / 1024
        if mib < 10 { return ((mib * 10).rounded(.down)) / 10 + 10_000 }
        if mib < 1000 { return mib.rounded(.down) + 1_000_000 }
        let gib = mib / 1024
        return ((gib * 10).rounded(.down)) / 10 + 100_000_000
    }

    /// Quantises a watts value to the granularity
    /// `MenuBarSegmentBlock.shortWatts` actually renders:
    ///   - <10W  -> 0.1W steps  ("9.9W")
    ///   - >=10W -> 1W steps    (" 12W", "999W")
    /// Mirrors `shortWatts`'s formatter rounding (`%.1f` → half-even,
    /// `%.0f` → half-even) closely enough that visible label
    /// boundaries also cross signature boundaries.
    private static func bucketWatts(_ value: Double?) -> Double {
        guard let value, value > 0 else { return 0 }
        if value < 10 { return (value * 10).rounded() / 10 }
        return value.rounded() + 10_000
    }

    /// Hashes the visible window of a percent-style history (CPU/MEM)
    /// using only the value channel so identical bar layouts produce
    /// identical signatures regardless of how the timestamps advance.
    /// `step` controls the quantisation grid: `1` ≈ 1 percentage point,
    /// matching the resolution of a 16 px tall menu-bar bar chart.
    private static func hashHistory(_ history: [MetricSample], step: Double) -> Int {
        var hasher = Hasher()
        hasher.combine(history.count)
        for sample in history {
            hasher.combine(Int((sample.value / step).rounded()))
        }
        return hasher.finalize()
    }

    /// Same as `hashHistory(_:step:)` but quantises through
    /// `bucketRate(_:)` so the rate-style chart's signature changes
    /// only when a displayed bar actually crosses a bucket boundary.
    private static func hashRateHistory(_ history: [MetricSample]) -> Int {
        var hasher = Hasher()
        hasher.combine(history.count)
        for sample in history {
            hasher.combine(Int(bucketRate(sample.value) * 10))
        }
        return hasher.finalize()
    }
}

private struct StatusBarPalette {
    let foreground: Color
    let divider: Color
    let usesLightText: Bool
    let generation: Int
}

/// Decides whether the status bar label should render light or dark
/// text. The final label cannot be a template image because graph
/// segments need real colors, so scalar text is rasterized from the
/// current status-button tint with appearance and desktop-picture
/// fallbacks.
@MainActor
private final class StatusBarForeground: ObservableObject {
    static let shared = StatusBarForeground()

    private static let desktopNotificationNames: [NSNotification.Name] = [
        NSNotification.Name("com.apple.desktop.changed"),
        NSNotification.Name("com.apple.DesktopPictureChanged"),
        NSNotification.Name("AppleDesktopPictureChangedNotification"),
    ]
    private static let wallpaperDarkThreshold = 0.56

    @Published private(set) var generation: Int = 0
    private var cachedPalette: StatusBarPalette?
    private var cachedGeneration: Int = -1
    private var cachedStatusAppearanceKey: String?
    private var desktopFingerprint: String = ""
    private var wallpaperDecision: WallpaperTextDecision?
    private var desktopPollTask: Task<Void, Never>?
    private let probeItem = NSStatusBar.system.statusItem(withLength: 0)

    private init() {
        Self.configureTemplateProbe(probeItem.button)
        desktopFingerprint = Self.currentDesktopFingerprint()

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handleDesktopMayHaveChanged(force: true) }
        }

        for name in Self.desktopNotificationNames {
            DistributedNotificationCenter.default().addObserver(
                forName: name,
                object: nil,
                queue: .main,
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.handleDesktopMayHaveChanged(force: true) }
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handleDesktopMayHaveChanged(force: true) }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handleDesktopMayHaveChanged(force: true) }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.handleDesktopMayHaveChanged(force: true) }
        }

        // The app appearance and desktop picture can settle a tick
        // after launch. Re-sample a few times so a dark menu bar does
        // not get stuck with the initial Light-Mode black fallback.
        scheduleStartupInvalidation(after: .milliseconds(0))
        scheduleStartupInvalidation(after: .milliseconds(150))
        scheduleStartupInvalidation(after: .milliseconds(600))

        desktopPollTask = Task { [weak self] in
            await self?.pollDesktopFingerprint()
        }
    }

    func palette(statusButton: NSButton? = nil) -> StatusBarPalette {
        let statusAppearanceKey = Self.statusAppearanceKey(
            statusButton,
            fallbackButton: probeItem.button,
        )
        if let cachedPalette,
           cachedGeneration == generation,
           cachedStatusAppearanceKey == statusAppearanceKey
        {
            return cachedPalette
        }

        let usesLightText = computeUsesLightText(statusButton: statusButton)
        let foreground: Color = usesLightText ? .white : .black
        let dividerOpacity = usesLightText ? 0.55 : 0.45
        let palette = StatusBarPalette(
            foreground: foreground,
            divider: foreground.opacity(dividerOpacity),
            usesLightText: usesLightText,
            generation: generation,
        )
        cachedPalette = palette
        cachedGeneration = generation
        cachedStatusAppearanceKey = statusAppearanceKey
        return palette
    }

    private func pollDesktopFingerprint() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            refreshBackdrop()
        }
    }

    private func handleDesktopMayHaveChanged(force: Bool) {
        refreshBackdrop(forceInvalidate: force)
        scheduleStartupInvalidation(after: .milliseconds(150))
        scheduleStartupInvalidation(after: .milliseconds(600))
    }

    private func refreshBackdrop(forceInvalidate: Bool = false) {
        let nextFingerprint = Self.currentDesktopFingerprint()
        let desktopChanged = nextFingerprint != desktopFingerprint
        if desktopChanged {
            desktopFingerprint = nextFingerprint
        }
        if forceInvalidate || desktopChanged {
            wallpaperDecision = nil
        }
        if forceInvalidate || desktopChanged {
            invalidate()
        }
    }

    private func invalidate() {
        generation += 1
        cachedPalette = nil
        cachedStatusAppearanceKey = nil
    }

    private func scheduleStartupInvalidation(after delay: DispatchTimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.refreshBackdrop(forceInvalidate: true) }
        }
    }

    private func computeUsesLightText(statusButton: NSButton?) -> Bool {
        if let usesLightText = Self.statusIconUsesLightText(statusButton)
            ?? Self.statusIconUsesLightText(probeItem.button)
        {
            return usesLightText
        }
        if let usesLightText = Self.computeUsesLightText(probeButton: statusButton)
            ?? Self.computeUsesLightText(probeButton: probeItem.button)
            ?? Self.computeUsesLightText(appearance: NSApp.effectiveAppearance)
        {
            return usesLightText
        }
        if let wallpaperUsesLightText = computeWallpaperUsesLightText() {
            return wallpaperUsesLightText
        }
        return false
    }

    private func computeWallpaperUsesLightText() -> Bool? {
        let fingerprint = desktopFingerprint
        if let wallpaperDecision, wallpaperDecision.fingerprint == fingerprint {
            return wallpaperDecision.usesLightText
        }

        guard let usesLightText = Self.computeWallpaperUsesLightText() else {
            wallpaperDecision = nil
            return nil
        }
        wallpaperDecision = WallpaperTextDecision(
            fingerprint: fingerprint,
            usesLightText: usesLightText,
        )
        return usesLightText
    }

    private static func computeUsesLightText(probeButton: NSButton?) -> Bool? {
        guard let probeButton else { return nil }
        return computeUsesLightText(appearance: probeButton.effectiveAppearance)
    }

    private static func computeUsesLightText(appearance: NSAppearance) -> Bool? {
        let match = appearance.bestMatch(
            from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight],
        )
        switch match {
        case .darkAqua, .vibrantDark:
            return true
        case .aqua, .vibrantLight:
            return false
        default:
            return nil
        }
    }

    private static func statusAppearanceKey(
        _ button: NSButton?,
        fallbackButton: NSButton?,
    ) -> String {
        let resolvedButton = button ?? fallbackButton
        let appearance = resolvedButton?.effectiveAppearance ?? NSApp.effectiveAppearance
        let match = appearance.bestMatch(
            from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight],
        )?.rawValue ?? "unknown"
        let screenName = resolvedButton?.window?.screen?.localizedName
            ?? NSScreen.main?.localizedName
            ?? "no-screen"
        let tintKey = statusIconTintKey(button)
            ?? statusIconTintKey(fallbackButton)
            ?? "no-tint"
        return "\(screenName)|\(match)|\(tintKey)"
    }

    private static func statusIconUsesLightText(_ button: NSButton?) -> Bool? {
        guard let button,
              let tint = button.contentTintColor,
              let luminance = relativeLuminance(of: tint, appearance: button.effectiveAppearance)
        else {
            return nil
        }
        return luminance >= 0.5
    }

    private static func statusIconTintKey(_ button: NSButton?) -> String? {
        guard let button,
              let tint = button.contentTintColor,
              let color = resolvedRGBColor(tint, appearance: button.effectiveAppearance)
        else {
            return nil
        }
        return String(
            format: "tint:%.3f,%.3f,%.3f,%.3f",
            Double(color.redComponent),
            Double(color.greenComponent),
            Double(color.blueComponent),
            Double(color.alphaComponent),
        )
    }

    private static func relativeLuminance(
        of color: NSColor,
        appearance: NSAppearance,
    ) -> Double? {
        guard let rgb = resolvedRGBColor(color, appearance: appearance) else { return nil }
        return 0.2126 * Double(rgb.redComponent)
            + 0.7152 * Double(rgb.greenComponent)
            + 0.0722 * Double(rgb.blueComponent)
    }

    private static func resolvedRGBColor(
        _ color: NSColor,
        appearance: NSAppearance,
    ) -> NSColor? {
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(NSColorSpace.deviceRGB)
        }
        return resolved
    }

    private static func configureTemplateProbe(_ button: NSButton?) {
        guard let button else { return }
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 8, height: 8)).fill()
        image.unlockFocus()
        image.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
    }

    private static func computeWallpaperUsesLightText() -> Bool? {
        guard let screen = targetScreen(),
              let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let luminance = wallpaperTopStripLuminance(url: url)
        else {
            return nil
        }
        return luminance < wallpaperDarkThreshold
    }

    private static func currentDesktopFingerprint() -> String {
        guard let screen = targetScreen() else { return "no-screen" }

        let workspace = NSWorkspace.shared
        let url = workspace.desktopImageURL(for: screen)
        let path = url?.path ?? "no-url"
        let modifiedAt = url.flatMap { url in
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?
                .timeIntervalSince1970
        } ?? 0
        let options = workspace.desktopImageOptions(for: screen) ?? [:]
        let optionString = options
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: ";")

        return [
            screen.localizedName,
            "\(Int(screen.frame.width))x\(Int(screen.frame.height))",
            path,
            "\(modifiedAt)",
            optionString,
        ].joined(separator: "|")
    }

    private static func targetScreen() -> NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }

    private static func wallpaperTopStripLuminance(url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue

        return pixels.withUnsafeMutableBytes { buffer -> Double? in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo,
                  )
            else {
                return nil
            }

            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

            let pixelBytes = baseAddress.assumingMemoryBound(to: UInt8.self)
            let stripRows = max(1, height / 6)
            let startRow = max(0, height - stripRows)
            var luminanceSum = 0.0
            var sampledPixels = 0

            for row in startRow ..< height {
                let rowOffset = row * bytesPerRow
                for column in 0 ..< width {
                    let offset = rowOffset + column * bytesPerPixel
                    let alpha = Double(pixelBytes[offset + 3]) / 255.0
                    guard alpha > 0.01 else { continue }

                    let red = Double(pixelBytes[offset]) / 255.0
                    let green = Double(pixelBytes[offset + 1]) / 255.0
                    let blue = Double(pixelBytes[offset + 2]) / 255.0
                    luminanceSum += 0.2126 * red + 0.7152 * green + 0.0722 * blue
                    sampledPixels += 1
                }
            }

            guard sampledPixels > 0 else { return nil }
            return luminanceSum / Double(sampledPixels)
        }
    }
}

private struct WallpaperTextDecision {
    let fingerprint: String
    let usesLightText: Bool
}
