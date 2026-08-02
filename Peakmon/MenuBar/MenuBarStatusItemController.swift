//
//  MenuBarStatusItemController.swift
//  Peakmon
//

import AppKit
import Combine
import PeakmonCore
import PeakmonUI
import SwiftUI

@MainActor
final class MenuBarStatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let store: MetricsStore
    private let historyIssuesStore: HistoryIssuesStore
    private let runtime: MetricsRuntime
    private let onShowDashboard: () -> Void
    private var cache = MenuBarLabelCache()
    private var menuBarEnabled = true
    private var popoverEnabled = true
    nonisolated(unsafe) private var updateTimer: Timer?
    nonisolated(unsafe) private var defaultsObserver: NSObjectProtocol?
    private var foregroundCancellable: AnyCancellable?

    init(
        store: MetricsStore,
        processesStore: ProcessesStore,
        historyIssuesStore: HistoryIssuesStore,
        runtime: MetricsRuntime,
        onShowDashboard: @escaping () -> Void,
        onShowHistory: @escaping (HistoryAnomalyEvent?) -> Void,
    ) {
        self.store = store
        self.historyIssuesStore = historyIssuesStore
        self.runtime = runtime
        self.onShowDashboard = onShowDashboard
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = CGSize(width: DashboardView.popoverWidth, height: DashboardView.popoverHeight)

        super.init()

        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView:
            CardSettingsScope {
                DashboardView { [weak self] event in
                    self?.popover.performClose(nil)
                    onShowHistory(event)
                }
                .environment(store)
                .environment(processesStore)
                .environment(historyIssuesStore)
                .environment(runtime)
            }
        )
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = AppLanguage.current.localizedString(for: "Peakmon")
            button.setAccessibilityLabel(AppLanguage.current.localizedString(for: "Peakmon"))
        }
    }

    deinit {
        updateTimer?.invalidate()
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    func start() {
        refreshSurfacePreferences()

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
                self?.refreshSurfacePreferences()
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
        guard menuBarEnabled else { return }
        guard popoverEnabled else {
            onShowDashboard()
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            scheduleStartupRender(after: .milliseconds(120))
        }
    }

    func togglePopoverFromHotKey() {
        guard menuBarEnabled, popoverEnabled else { return }
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

    private func refreshSurfacePreferences() {
        menuBarEnabled = AppSurfacePreferences.menuBarEnabled
        popoverEnabled = AppSurfacePreferences.popoverEnabled
        statusItem.isVisible = menuBarEnabled
        if let button = statusItem.button {
            let appName = AppLanguage.current.localizedString(for: "Peakmon")
            button.toolTip = appName
            button.setAccessibilityLabel(appName)
        }

        guard menuBarEnabled, popoverEnabled else {
            if popover.isShown {
                popover.performClose(nil)
            }
            runtime.popoverVisible = false
            runtime.popoverNeedsProcesses = false
            if !menuBarEnabled {
                runtime.updateMenuBarSegments([])
            }
            return
        }
    }

    private func renderStatusItem(force: Bool = false) {
        guard menuBarEnabled else { return }

        let items = menuBarSegments()
        runtime.updateMenuBarSegments(items)

        let tints = menuBarTints()
        let palette = StatusBarForeground.shared.palette(statusButton: statusItem.button)
        let signature = MenuBarLabelSignature.make(
            store: store,
            items: items,
            tints: tints,
            historyIssuesStore: historyIssuesStore,
            usesLightText: palette.usesLightText,
            appearanceGeneration: palette.generation,
        )

        let image = cache.image(for: signature, force: force) {
            Self.renderImage(
                store: store,
                items: items,
                tints: tints,
                historyIssuesStore: historyIssuesStore,
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
        // Let AppKit apply the status-bar spacing for the running macOS
        // release. A fixed image-width adjustment bypasses the system
        // content insets and makes the item sit too close to its
        // neighbours on macOS 26 and later.
        statusItem.length = NSStatusItem.variableLength
    }

    private func menuBarSegments() -> [MenuBarSegment] {
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
        historyIssuesStore: HistoryIssuesStore,
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
                    historyIssuesStore: historyIssuesStore,
                )
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(palette.foreground)
        .frame(height: 22)
        .fixedSize()
        .environment(\.locale, AppLanguage.current.locale)

        let renderer = ImageRenderer(content: composed)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage
        image?.isTemplate = false
        return image
    }
}
