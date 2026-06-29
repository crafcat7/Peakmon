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
    @Environment(MetricsRuntime.self) private var runtime
    @Environment(\.cardSettings) private var cardSettings
    /// Visibility gate: when the main window isn't key, is
    /// minimised, or is fully occluded, swap the expensive subtree
    /// for an empty placeholder so SwiftUI stops re-evaluating six
    /// cards and the process table on every `MetricsStore` tick.
    /// Becoming visible rebuilds from the current (still-fresh)
    /// snapshot since the scheduler kept running.
    @State private var visibility = MainWindowVisibility.shared

    private enum Layout {
        static let columnSpacing: CGFloat = 16
        static let rowSpacing: CGFloat = 14
        static let horizontalPadding: CGFloat = 24
        static let topPadding: CGFloat = 12
        static let bottomPadding: CGFloat = 40
    }

    var body: some View {
        let needsProcesses = visibility.isMainWindowActive && cardSettings.visibility(.processes)

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
        .onDisappear {
            runtime.mainDashboardVisible = false
            runtime.mainDashboardNeedsProcesses = false
        }
        .onChange(of: visibility.isMainWindowActive, initial: true) { _, value in
            runtime.mainDashboardVisible = value
        }
        .onChange(of: needsProcesses, initial: true) { _, value in
            runtime.mainDashboardNeedsProcesses = value
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
            LazyVStack(alignment: .leading, spacing: Layout.rowSpacing) {
                DashboardSystemBanner()
                    .frame(maxWidth: .infinity)
                cardRow(height: dashboardCardMinHeight) {
                    DashboardCPUCard()
                } right: {
                    DashboardMemoryCard()
                }
                cardRow(height: dashboardCardMinHeight) {
                    DashboardGPUCard()
                } right: {
                    DashboardPowerCard()
                }
                cardRow(height: dashboardRateCardMinHeight) {
                    DashboardDiskCard()
                } right: {
                    DashboardNetworkCard()
                }
                if cardSettings.visibility(.processes) {
                    DashboardProcessesPanel()
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, Layout.horizontalPadding)
            .padding(.top, Layout.topPadding)
            .padding(.bottom, Layout.bottomPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .transaction { transaction in
            // Metric ticks arrive as often as every 500 ms. Letting
            // every numeric text and sparkline change animate keeps
            // RenderBox redrawing interpolated display lists between
            // ticks; the dashboard is clearer and much cheaper when
            // live values snap to the latest sample.
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private func cardRow<Left: View, Right: View>(
        height: CGFloat,
        @ViewBuilder left: () -> Left,
        @ViewBuilder right: () -> Right,
    ) -> some View {
        HStack(alignment: .top, spacing: Layout.columnSpacing) {
            left()
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: height, alignment: .topLeading)
                .clipped()
            right()
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: height, alignment: .topLeading)
                .clipped()
        }
    }
}
