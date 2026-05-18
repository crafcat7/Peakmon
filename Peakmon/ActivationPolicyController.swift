//
//  ActivationPolicyController.swift
//  Peakmon
//
//  Peakmon ships as an `LSUIElement` (menu-bar-only) app, so by
//  default it carries no Dock icon. When the user opens the Settings
//  window we transition the activation policy to `.regular` so the
//  Dock icon appears and the window can be cmd-tabbed to; when the
//  Settings window closes we drop back to `.accessory` to keep the
//  Dock clean.
//

import AppKit
import OSLog
import PeakmonCore
import SwiftUI

/// Tracks visible app windows (excluding the menu-bar popover) and
/// flips `NSApp.setActivationPolicy` accordingly.
@MainActor
final class ActivationPolicyController {
    static let shared = ActivationPolicyController()

    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// Begin observing window lifecycle notifications. Idempotent.
    func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let queue = OperationQueue.main

        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: queue,
        ) { _ in
            Task { @MainActor in Self.shared.refresh() }
        })

        observers.append(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: queue,
        ) { _ in
            // Re-evaluate after the close finishes so the window is no
            // longer counted in `NSApp.windows`.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                Self.shared.refresh()
            }
        })
    }

    /// Manually request the regular policy and bring the app forward.
    /// Used when programmatically opening Settings on launch.
    func activateRegular() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Inspect the current window list and pick the right policy.
    func refresh() {
        let hasUserWindow = NSApp.windows.contains { window in
            guard window.isVisible else { return false }
            // Ignore the menu-bar popover, status item host, system
            // chrome and any zero-sized utility windows.
            let className = String(describing: type(of: window))
            if className.contains("MenuBarExtra") { return false }
            if className.contains("StatusBar") { return false }
            if className.contains("NSStatusBarWindow") { return false }
            if className.contains("Popover") { return false }
            // The Settings scene window is an ordinary titled window.
            return window.styleMask.contains(.titled)
        }

        let desired: NSApplication.ActivationPolicy = hasUserWindow ? .regular : .accessory
        if NSApp.activationPolicy() != desired {
            NSApp.setActivationPolicy(desired)
            Log.app
                .debug(
                    "Activation policy → \(desired == .regular ? "regular" : "accessory", privacy: .public)",
                )
        }
    }
}
