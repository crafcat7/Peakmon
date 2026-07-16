//
//  LaunchAtLoginController.swift
//  Peakmon
//
//  Thin wrapper around `SMAppService.mainApp` that handles the
//  register/unregister handshake and exposes the macOS-reported
//  authorisation status so Settings UI can react to user actions
//  in System Settings → Login Items.
//

import PeakmonCore
import ServiceManagement
import SwiftUI

/// Observable controller backing the "Launch Peakmon at login"
/// toggle. Keeps `isEnabled` in sync with `SMAppService.status`,
/// surfaces error messages, and refreshes when the app becomes
/// active (so user-initiated changes from System Settings flow
/// back into the UI).
@MainActor
@Observable
final class LaunchAtLoginController {
    /// Reflects whether the login item is currently registered.
    /// `true` matches `SMAppService.Status.enabled`.
    private(set) var isEnabled = false

    /// Set when the user-toggled action requires intervention in
    /// System Settings (e.g. macOS marked the service as
    /// `requiresApproval`). UI binds to this to show inline hints.
    private(set) var requiresApproval = false

    /// Last error description from a failed register/unregister,
    /// or `nil` after a successful action.
    private(set) var lastError: String?

    private let service = SMAppService.mainApp

    init() {
        refresh()
    }

    /// Re-reads `SMAppService.status` and updates the observable
    /// state. Cheap; safe to call from `onAppear` and from
    /// notifications observers.
    func refresh() {
        let status = service.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    /// Registers or unregisters the app as a login item. Updates
    /// `isEnabled`/`lastError` on completion. Returns whether the
    /// requested state change succeeded so callers (the Settings
    /// toggle) can revert if `SMAppService` rejects the change.
    @discardableResult
    func setEnabled(_ desired: Bool) -> Bool {
        do {
            if desired {
                try service.register()
            } else {
                try service.unregister()
            }
            lastError = nil
            refresh()
            return isEnabled == desired
        } catch {
            lastError = error.localizedDescription
            refresh()
            return false
        }
    }
}
