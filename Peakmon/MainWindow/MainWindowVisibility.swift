//
//  MainWindowVisibility.swift
//  Peakmon
//
//  Tracks whether the unified `Window("main")` scene is currently
//  doing useful work for the user (i.e. visible, on-screen, not
//  minimised, and either key or at least not occluded). The
//  Dashboard surface reads this and stops rebuilding its
//  SwiftUI subtree when the window is hidden, which is the
//  single largest reduction in CPU on long-running sessions:
//
//    • The menu-bar entry and popover keep ticking off the same
//      `MetricsStore` because they only paint a handful of glyphs.
//    • The Dashboard, in contrast, paints ~8 sparklines, a 50-row
//      process table, and several gradients per `MetricsStore`
//      change. With the main window hidden behind another app
//      that work is invisible yet still ran every second, costing
//      ~17% CPU on an M-class core.
//
//  When `isMainWindowActive` is false, `DashboardSurface` swaps
//  in a tiny `Color.clear` placeholder. SwiftUI tears down the
//  expensive subtree, the `MetricsStore` updates trigger no
//  body re-evaluation, and `CA::Transaction::commit` goes idle.
//  Becoming key/visible rebuilds the subtree from the current
//  `MetricsStore` state, which is up-to-date because the
//  scheduler kept running in the background.
//

import AppKit
import SwiftUI

/// Observable wrapper around the AppKit notifications that
/// indicate whether the main window is currently doing useful
/// painting. Lives as a single `shared` instance because there
/// is exactly one `Window("main")` in the app and SwiftUI's
/// scene API does not expose a per-window visibility binding.
@MainActor
@Observable
final class MainWindowVisibility {
    static let shared = MainWindowVisibility()

    /// True when at least one titled, on-screen, non-minimised
    /// window owned by this app is currently key OR visible on
    /// the active space. Defaults to `true` so the dashboard
    /// renders correctly on first launch before any window
    /// notification has fired.
    private(set) var isMainWindowActive: Bool = true

    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// Begin observing AppKit notifications. Idempotent.
    func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let queue = OperationQueue.main

        // Notifications we care about. We don't filter by
        // window object because there's only one user-facing
        // titled window, and the menu-bar popover/status host
        // are filtered out inside `recompute()` the same way
        // `ActivationPolicyController` does.
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
            NSApplication.didChangeOcclusionStateNotification,
        ]
        for name in names {
            observers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: queue,
            ) { _ in
                Task { @MainActor in
                    // Tiny delay so `NSApp.windows` reflects
                    // the post-notification state (e.g. after
                    // `willClose`).
                    try? await Task.sleep(for: .milliseconds(30))
                    Self.shared.recompute()
                }
            })
        }
        recompute()
    }

    /// Inspect `NSApp.windows` and decide whether the main
    /// window is currently worth painting.
    func recompute() {
        let active = NSApp.windows.contains { window in
            guard window.isVisible else { return false }
            if window.isMiniaturized { return false }
            // Filter out menu-bar / status / popover windows so
            // we only count the real titled `Window("main")`.
            let className = String(describing: type(of: window))
            if className.contains("MenuBarExtra") { return false }
            if className.contains("StatusBar") { return false }
            if className.contains("NSStatusBarWindow") { return false }
            if className.contains("Popover") { return false }
            guard window.styleMask.contains(.titled) else { return false }
            // `occlusionState` is empty when fully covered by
            // other apps; treat that as inactive too.
            if !window.occlusionState.contains(.visible) { return false }
            return true
        }
        if active != isMainWindowActive {
            isMainWindowActive = active
        }
    }
}
