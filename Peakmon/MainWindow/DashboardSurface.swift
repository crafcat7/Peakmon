//
//  DashboardSurface.swift
//  Peakmon
//
//  Full-width dashboard rendered inside the unified main window
//  when the top pill is on `MainWindowTab.dashboard`.
//
//  Layout: a system identity banner on top, then six metric
//  cards laid out as three 2-column rows (CPU + Memory, GPU +
//  Power, Disk + Network) built on the shared
//  `DashboardMetricCard` template, then the full-width
//  `DashboardProcessesPanel` for the "which app is doing this"
//  view that used to live inline inside the CPU + Memory cards.
//
//  The page title is intentionally NOT printed at the top — the
//  top pill already reads "Dashboard". Duplicating it in 34pt
//  immediately below would waste a third of the first screen.
//

import PeakmonCore
import SwiftUI

struct DashboardSurface: View {
    @Environment(MetricsStore.self) private var store
    /// Window visibility gate. When the main window is not key,
    /// minimised, or fully occluded by another app, swap the
    /// expensive subtree for an empty placeholder so SwiftUI
    /// stops re-evaluating six metric cards and a 50-row
    /// process table on every `MetricsStore` tick. Becoming
    /// visible again rebuilds from the current store snapshot,
    /// which is fresh because the scheduler kept running.
    @State private var visibility = MainWindowVisibility.shared

    /// Hand-laid 2-column rows backed by the shared
    /// `DashboardMetricCard` template, which enforces a uniform
    /// `dashboardCardMinHeight` so siblings on the same row reach
    /// the same height and `HStack` doesn't leave whitespace
    /// under shorter cards. Below the card cluster sits the
    /// full-width `DashboardProcessesPanel`, the "which app" view
    /// that used to be embedded inside CPU + Memory cards.
    var body: some View {
        Group {
            if visibility.isMainWindowActive {
                activeContent
            } else {
                // Placeholder paints once and never re-evaluates
                // its body on `MetricsStore` changes because it
                // doesn't read the store. CPU drops to whatever
                // the menu bar + popover need.
                Color.clear
            }
        }
    }

    @ViewBuilder
    private var activeContent: some View {
        ScrollView {
            // `LazyVStack` (versus plain `VStack`) keeps off-screen
            // cards out of the view tree until they scroll close to
            // the viewport. Trade-off: each card has to rebuild
            // once when it re-enters, but every card's data lives
            // in the shared `MetricsStore`, so the rebuild is a
            // cheap copy. The win is a smaller SwiftUI
            // `DisplayList` per frame — `render_contents` was
            // dominating the main thread during scrolling because
            // the previous eager `VStack` forced all six cards +
            // banner + 50-row process table into every rasterise
            // pass even when only two were visible.
            LazyVStack(alignment: .leading, spacing: 16) {
                // Identity banner pinned above the metric grid.
                // Keeps "which Mac am I looking at" answerable
                // without leaving the dashboard.
                DashboardSystemBanner()
                    .frame(maxWidth: .infinity)
                HStack(alignment: .top, spacing: 16) {
                    DashboardCPUCard()
                        .frame(maxWidth: .infinity)
                    DashboardMemoryCard()
                        .frame(maxWidth: .infinity)
                }
                HStack(alignment: .top, spacing: 16) {
                    DashboardGPUCard()
                        .frame(maxWidth: .infinity)
                    DashboardPowerCard()
                        .frame(maxWidth: .infinity)
                }
                HStack(alignment: .top, spacing: 16) {
                    DashboardDiskCard()
                        .frame(maxWidth: .infinity)
                    DashboardNetworkCard()
                        .frame(maxWidth: .infinity)
                }
                DashboardProcessesPanel()
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

#Preview {
    DashboardSurface()
        .frame(width: 1000, height: 680)
        .environment(MetricsStore())
        .environment(ProcessesStore())
}
