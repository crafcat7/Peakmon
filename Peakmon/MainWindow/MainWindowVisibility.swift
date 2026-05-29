//
//  MainWindowVisibility.swift
//  Peakmon
//
//  Tracks whether the unified `Window("main")` scene is doing
//  useful work (visible, on-screen, not minimised, key or at least
//  not occluded). `DashboardSurface` reads this and stops rebuilding
//  its SwiftUI subtree when the window is hidden — the single
//  largest CPU win on long sessions.
//
//  The menu-bar entry and popover keep ticking (they paint a few
//  glyphs), but the Dashboard's ~8 sparklines + process table +
//  gradients would otherwise re-render every second behind another
//  app, costing ~17% of an M-class core. When inactive, the surface
//  swaps in a `Color.clear` placeholder so store updates trigger no
//  body re-eval; becoming visible rebuilds from the current (still
//  fresh) store state.
//

import AppKit
import SwiftUI

/// Observable wrapper around the AppKit notifications that signal
/// whether the main window is painting. A single `shared` instance
/// since there's exactly one `Window("main")` and SwiftUI exposes no
/// per-window visibility binding.
@MainActor
@Observable
final class MainWindowVisibility {
    static let shared = MainWindowVisibility()

    /// True when at least one titled, on-screen, non-minimised app
    /// window is key or visible. Defaults to `true` so the dashboard
    /// renders on first launch before any notification fires.
    private(set) var isMainWindowActive: Bool = true

    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// Begin observing AppKit notifications. Idempotent.
    func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let queue = OperationQueue.main

        // No window-object filter: there's only one titled window,
        // and the status/popover hosts are filtered in `recompute()`.
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
                    // Small delay so `NSApp.windows` reflects the
                    // post-notification state (e.g. after `willClose`).
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
