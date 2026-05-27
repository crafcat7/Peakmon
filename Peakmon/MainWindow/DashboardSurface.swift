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

    /// Hand-laid 2-column rows backed by the shared
    /// `DashboardMetricCard` template, which enforces a uniform
    /// `dashboardCardMinHeight` so siblings on the same row reach
    /// the same height and `HStack` doesn't leave whitespace
    /// under shorter cards. Below the card cluster sits the
    /// full-width `DashboardProcessesPanel`, the "which app" view
    /// that used to be embedded inside CPU + Memory cards.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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
