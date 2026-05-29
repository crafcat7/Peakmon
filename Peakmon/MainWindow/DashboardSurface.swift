//
//  DashboardSurface.swift
//  Peakmon
//
//  Full-width dashboard shown when the top pill is on
//  `MainWindowTab.dashboard`: a system identity banner, then six
//  metric cards in three 2-column rows (CPU + Memory, GPU + Power,
//  Disk + Network) on the shared `DashboardMetricCard` template,
//  then the full-width `DashboardProcessesPanel`.
//
//  No page title at the top — the pill already reads "Dashboard";
//  repeating it in 34pt would waste a third of the first screen.
//

import PeakmonCore
import SwiftUI

struct DashboardSurface: View {
    @Environment(MetricsStore.self) private var store
    /// Visibility gate: when the main window isn't key, is
    /// minimised, or is fully occluded, swap the expensive subtree
    /// for an empty placeholder so SwiftUI stops re-evaluating six
    /// cards and the process table on every `MetricsStore` tick.
    /// Becoming visible rebuilds from the current (still-fresh)
    /// snapshot since the scheduler kept running.
    @State private var visibility = MainWindowVisibility.shared

    var body: some View {
        Group {
            if visibility.isMainWindowActive {
                activeContent
            } else {
                // Placeholder never re-evaluates on store changes
                // (it doesn't read the store); CPU drops to whatever
                // the menu bar + popover need.
                Color.clear
            }
        }
    }

    @ViewBuilder
    private var activeContent: some View {
        ScrollView {
            // `LazyVStack` keeps off-screen cards out of the view
            // tree until they near the viewport, shrinking the
            // per-frame `DisplayList`. The eager `VStack` previously
            // forced all six cards + banner + process table into
            // every rasterise pass, making `render_contents`
            // dominate the main thread during scroll. Each card
            // rebuilds once on re-entry, but its data lives in the
            // shared `MetricsStore` so that's a cheap copy.
            LazyVStack(alignment: .leading, spacing: 16) {
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
