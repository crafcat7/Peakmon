//
//  MainWindowSelection.swift
//  Peakmon
//
//  Single source of truth for which page the unified `Window("main")`
//  scene shows. v1.0–v1.2 had a separate `Window("settings")`; v1.3
//  folds dashboard + settings into one window driven by this enum.
//
//  Navigation shape (2026-05-26 rev 3):
//    • Top-level: a centered floating pill in the toolbar — Dashboard
//      / History / Settings.
//    • Inside Settings: a smaller segmented control switches three
//      sub-pages (General / Display / About), kept separate (not
//      merged) and relocated from the old sidebar to a sub-toolbar.
//
//  Rejected directions (kept so they aren't re-proposed):
//    • 8 sub-pages in a sidebar — too fragmented for a KPI monitor.
//    • NavigationSplitView w/ floating sidebar — clunky transitions,
//      cramped at 1000pt. Hence the top centered pill, no sidebar.
//

import SwiftUI

/// Which page the unified main window is rendering.
///
/// - `.dashboard`: full-width KPI grid; default landing for ⌘, and
///   the popover's "Open Window" footer.
/// - `.history`: local diagnostics timeline and anomaly review.
/// - `.settings(category)`: classic sidebar+detail settings layout,
///   one detail page per `SettingsCategory`.
enum MainWindowSelection: Hashable {
    case dashboard
    case history
    case settings(SettingsCategory)

    /// Page opened when ⌘, or the popover's "Open Window" footer
    /// launches with no prior selection. Anchored on the dashboard
    /// so the shortcut means "show me the monitor", not the config.
    static let defaultLanding: MainWindowSelection = .dashboard

    /// Appended to the window title ("Peakmon — <title>") and used by
    /// the Dashboard sidebar row.
    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .history: "History"
        case .settings(let category): category.title
        }
    }

    /// SF Symbol used for the Dashboard sidebar row. Settings rows
    /// pull their glyph from `SettingsCategory.systemImage`.
    var systemImage: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .history: "chart.xyaxis.line"
        case .settings(let category): category.systemImage
        }
    }

    /// Tint applied to the sidebar row glyph container.
    var tint: Color {
        switch self {
        case .dashboard: .accentColor
        case .history: .purple
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
    case history
    case settings

    var id: Self { self }

    /// Display label inside the floating pill.
    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .history: "History"
        case .settings: "Settings"
        }
    }

    /// SF Symbol shown next to the label inside the pill. Kept
    /// neutral (no domain tint) so the pill reads as navigation
    /// chrome, not a status indicator.
    var systemImage: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .history: "chart.xyaxis.line"
        case .settings: "slider.horizontal.3"
        }
    }
}
