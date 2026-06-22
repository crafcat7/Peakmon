//
//  MainWindowView.swift
//  Peakmon
//
//  Root view of the unified `Window("main")` scene: a top-pill nav
//  (`MainWindowTopBar`) floating over a detail surface that is either
//  `DashboardSurface` or `SettingsSurface`.
//
//  The scene's title bar is hidden (`.hiddenTitleBar` in `PeakmonApp`),
//  so the pill is the only top chrome; the window stays draggable from
//  the empty area since hidden title bars keep their hit-test region.
//
//  Keeps `selection: MainWindowSelection` (not just `MainWindowTab`)
//  because `PeakmonApp` owns that `@State`, the v1.4 plan may add
//  deeplinks like `openWindow(value: .settings(.display))`, and the
//  Settings sub-pill needs the `SettingsCategory` from the enum.
//
//  Pill ↔ selection mapping:
//    • Dashboard ⇒ .dashboard
//    • Settings  ⇒ .settings(remembered), remembered = last sub-
//      category picked, defaulting to `.general`.
//

import PeakmonCore
import PeakmonUI
import SwiftUI

struct MainWindowView: View {
    @Binding var selection: MainWindowSelection

    /// Last `SettingsCategory` touched. Survives Dashboard ↔ Settings
    /// flips so returning to Settings restores the same sub-page
    /// instead of snapping to `.general`.
    @State private var lastSettingsCategory: SettingsCategory = .general

    var body: some View {
        ZStack(alignment: .top) {
            // Detail surface fills the window; the pill floats over
            // it with top padding.
            detailSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))

            MainWindowTopBar(selection: topTabBinding)
                .padding(.top, 12)
        }
        .frame(
            minWidth: 880,
            idealWidth: 1000,
            maxWidth: .infinity,
            minHeight: 600,
            idealHeight: 680,
            maxHeight: .infinity,
        )
    }

    /// Bridges `MainWindowTab` (pill) ↔ `MainWindowSelection` (scene
    /// state). Read derives the tab; write applies the remembered-
    /// sub-page rule from the header.
    private var topTabBinding: Binding<MainWindowTab> {
        Binding(
            get: {
                switch selection {
                case .dashboard: .dashboard
                case .settings: .settings
                }
            },
            set: { newTab in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    switch newTab {
                    case .dashboard:
                        selection = .dashboard
                    case .settings:
                        selection = .settings(lastSettingsCategory)
                    }
                }
            },
        )
    }

    /// Binding for `SettingsSurface`'s sub-pill. Also updates
    /// `lastSettingsCategory` so a later Dashboard→Settings round-trip
    /// remembers the choice.
    private var settingsCategoryBinding: Binding<SettingsCategory> {
        Binding(
            get: {
                if case let .settings(category) = selection {
                    return category
                }
                return lastSettingsCategory
            },
            set: { newCategory in
                lastSettingsCategory = newCategory
                selection = .settings(newCategory)
            },
        )
    }

    @ViewBuilder
    private var detailSurface: some View {
        // Pad down past the pill so the surface content doesn't slide
        // under it while avoiding a tall empty band above the dashboard.
        Group {
            switch selection {
            case .dashboard:
                DashboardSurface()
                    .transition(.opacity)
            case .settings:
                SettingsSurface(selection: settingsCategoryBinding)
                    .transition(.opacity)
            }
        }
        .padding(.top, 50)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: tabOf(selection))
    }

    /// Animates only on top-level tab changes, not on sub-pill flips
    /// inside Settings (which manages its own transition).
    private func tabOf(_ selection: MainWindowSelection) -> MainWindowTab {
        switch selection {
        case .dashboard: .dashboard
        case .settings: .settings
        }
    }
}

#Preview {
    MainWindowView(selection: .constant(.dashboard))
        .environment(MetricsStore())
        .environment(ProcessesStore())
        .environment(MetricsRuntime())
}
