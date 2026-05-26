//
//  MainWindowSelection.swift
//  Peakmon
//
//  Single source of truth for which page the unified `Window("main")`
//  scene is showing. v1.0–v1.2 had a standalone `Window("settings")`
//  scene; v1.3 folds both the dashboard surface and the settings
//  pages into one window driven by this enum.
//
//  Navigation shape (decided 2026-05-26 revision 3):
//    • Top-level: a centered floating pill in the toolbar with two
//      tabs — Dashboard and Settings. Reference design is the
//      third-party "monitor.app" screenshot the user shared.
//    • Inside Settings: a smaller pill segmented control switches
//      between three sub-pages (General / Display / About). The
//      three pages are NOT merged into one — the segmented control
//      just relocates from the previous sidebar to a sub-toolbar
//      under the main pill.
//
//  History of reverted directions (kept for context so future
//  iterations don't re-propose them):
//    • D0 draft: 8 sub-pages in a sidebar (Overview/CPU/Memory/…)
//      — rejected as too fragmented for KPI-style monitor.
//    • D1 v1: NavigationSplitView with floating sidebar rows,
//      two sections DASHBOARD + SETTINGS — rejected; transitions
//      felt clunky, layout cramped on a 1000pt window.
//    • Therefore D1 v2 (this file): top centered pill, no sidebar.
//

import SwiftUI

/// Which page the unified main window is rendering.
///
/// - `.dashboard`: full-width KPI grid; default landing for ⌘, and
///   the popover's "Open Window" footer.
/// - `.settings(category)`: classic sidebar+detail settings layout,
///   one detail page per `SettingsCategory`.
enum MainWindowSelection: Hashable {
    case dashboard
    case settings(SettingsCategory)

    /// Page opened when the popover's "Open Window" footer or ⌘,
    /// launches the window with no prior selection. The design
    /// anchors first-open on the dashboard rather than on a
    /// last-used settings tab so the shortcut feels like
    /// "show me the monitor", not "show me the config".
    static let defaultLanding: MainWindowSelection = .dashboard

    /// Title appended to the window title ("Peakmon — <title>")
    /// and used by the sidebar row for the Dashboard entry.
    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .settings(let category): category.title
        }
    }

    /// SF Symbol used for the Dashboard sidebar row. Settings rows
    /// pull their glyph from `SettingsCategory.systemImage`.
    var systemImage: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .settings(let category): category.systemImage
        }
    }

    /// Tint applied to the sidebar row glyph container.
    var tint: Color {
        switch self {
        case .dashboard: .accentColor
        case .settings(let category): category.tint
        }
    }
}

/// Top-level navigation slot in the unified main window. Exists as a
/// separate type from `MainWindowSelection` because the top pill only
/// needs to know "Dashboard or Settings"; which settings sub-page is
/// active is local to the Settings surface.
enum MainWindowTab: Hashable, CaseIterable, Identifiable {
    case dashboard
    case settings

    var id: Self { self }

    /// Display label inside the floating pill.
    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .settings: "Settings"
        }
    }

    /// SF Symbol shown next to the label inside the pill. Kept
    /// deliberately neutral (no domain tint) so the pill reads as
    /// a navigation chrome element, not a status indicator.
    var systemImage: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .settings: "slider.horizontal.3"
        }
    }
}
