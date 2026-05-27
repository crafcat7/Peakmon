//
//  MainWindowView.swift
//  Peakmon
//
//  Root view of the unified `Window("main")` scene. v1.3 D1 v2 ships
//  a top-pill navigation model instead of the briefly-tried sidebar:
//
//    ┌─ window ───────────────────────────────────────────────┐
//    │                                                        │
//    │           ╭─[ Dashboard | Settings ]─╮  ← TopBar pill   │
//    │                                                        │
//    │   ┌─ detail surface ─────────────────────────────────┐ │
//    │   │ DashboardSurface  or  SettingsSurface            │ │
//    │   └──────────────────────────────────────────────────┘ │
//    └────────────────────────────────────────────────────────┘
//
//  The scene's title bar is hidden (`windowStyle(.hiddenTitleBar)`
//  applied at the scene level in `PeakmonApp`), so the pill is the
//  only chrome at the top of the window. The window is still
//  draggable from the empty area around the pill because hidden
//  title bars preserve their hit-test region.
//
//  `selection: MainWindowSelection` is kept around (rather than
//  replaced with `MainWindowTab`) because:
//    1. `PeakmonApp` already owns a `@State` of that type and the
//       v1.4 plan may add deeplinks like
//       `openWindow(id: "main", value: .settings(.display))`.
//    2. The Settings sub-pill needs a `SettingsCategory` anyway,
//       and reading it from `MainWindowSelection.settings(_)`
//       avoids an additional `@State`.
//
//  Mapping rules between the top-pill `MainWindowTab` and the
//  enum `MainWindowSelection`:
//    • Top pill → Dashboard      ⇒ selection = .dashboard
//    • Top pill → Settings       ⇒ selection = .settings(remembered)
//      where `remembered` is the last sub-category the user picked,
//      defaulting to `.general` on first entry.
//

import PeakmonCore
import PeakmonUI
import SwiftUI

struct MainWindowView: View {
    @Binding var selection: MainWindowSelection

    /// Last `SettingsCategory` the user touched. Surviving across
    /// Dashboard ↔ Settings flips so toggling back to Settings
    /// returns to the same sub-page rather than always
    /// snapping to `.general`.
    @State private var lastSettingsCategory: SettingsCategory = .general

    var body: some View {
        ZStack(alignment: .top) {
            // Detail surface fills the entire window. The top pill
            // floats over it with vertical padding, matching the
            // reference design.
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

    /// Bridges `MainWindowTab` (top pill) ↔ `MainWindowSelection`
    /// (scene-level state). Reading derives the tab from the enum
    /// case; writing applies the "remembered settings sub-page"
    /// rule documented above.
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

    /// Binding handed to `SettingsSurface` so its sub-pill can
    /// mutate the active settings category. Side-effect: also
    /// updates `lastSettingsCategory` so a subsequent
    /// Dashboard→Settings round-trip remembers the choice.
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
        // Pad the surface down by the pill's height + breathing
        // room so its own content doesn't slide under the pill.
        // 12 (top inset) + ~32 (pill height) + 16 (gap) = 60.
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
        .padding(.top, 60)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: tabOf(selection))
    }

    /// Helper that animates only on top-level tab changes, not on
    /// every sub-pill flip inside Settings (which manages its own
    /// transition).
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
}
