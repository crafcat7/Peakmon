//
//  PeakmonApp.swift
//  Peakmon
//
//  Menu bar entry point. v0.1 wires up MetricsStore + MetricsScheduler
//  with a single CPUCollector so the label and dashboard render live
//  data.
//

import AppKit
import Foundation
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
    @State private var historyRecorder = HistoryRecorder(
        store: HistoryStore(
            persistenceURL: PeakmonApp.historyPersistenceURL,
            storagePolicy: .standard,
            retainedKinds: HistoryRecorder.defaultRecordedKinds,
        ),
    )
    @State private var processesStore = ProcessesStore()
    @State private var historyIssuesStore = HistoryIssuesStore()
    @State private var runtime = MetricsRuntime()
    @State private var menuBarStatusController: MenuBarStatusItemController?
    @State private var historyFlushObserver: NSObjectProtocol?
    @State private var historySampleSink: HistorySampleSink?
    @State private var didBootstrap = false
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
            CardSettingsScope {
                MainWindowView(selection: $mainSelection)
                    .environment(\.historyRecorder, historyRecorder)
                    .environment(store)
                    .environment(processesStore)
                    .environment(historyIssuesStore)
                    .environment(runtime)
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
                bootstrapIfNeeded()
                startRuntime()
            }
        }
        .onChange(of: samplingInterval) { _, newValue in
            runtime.updateInterval(seconds: newValue)
        }
        .onChange(of: showProcesses, initial: false) { _, newValue in
            runtime.processesEnabled = newValue
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

        installHistoryFlushObserver()
        installMenuBarStatusItem()
        installDashboardHotKey()
        installPopoverHotKey()

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
            historyIssuesStore: historyIssuesStore,
            runtime: runtime,
            onShowHistory: { event in
                historyIssuesStore.requestHistoryFocus(for: event)
                mainSelection = .history
                openWindow(id: "main")
                ActivationPolicyController.shared.activateRegular()
                MainWindowVisibility.shared.recompute()
            },
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
        guard !didBootstrap else {
            return
        }
        didBootstrap = true
        let recorder = historyRecorder
        Task.detached(priority: .utility) {
            await recorder.prepare()
        }
        bootstrap()
    }

    private func installHistoryFlushObserver() {
        guard historyFlushObserver == nil else { return }
        let historySampleSink = resolvedHistorySampleSink()
        historyFlushObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil,
        ) { _ in
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached(priority: .utility) {
                await historySampleSink.flush()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 1)
        }
    }

    private func startRuntime() {
        let historySampleSink = resolvedHistorySampleSink()
        runtime.start(
            store: store,
            historySampleSink: historySampleSink,
            processesStore: processesStore,
            interval: samplingInterval,
        )
        runtime.processesEnabled = showProcesses
    }

    private func resolvedHistorySampleSink() -> HistorySampleSink {
        if let historySampleSink {
            return historySampleSink
        }
        let sink = HistorySampleSink(
            recorder: historyRecorder,
            issuesStore: historyIssuesStore,
        )
        historySampleSink = sink
        return sink
    }

    private static var historyPersistenceURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Peakmon", isDirectory: true)
            .appendingPathComponent("history-buckets-v1.sqlite")
    }
}
