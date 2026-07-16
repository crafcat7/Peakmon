//
//  DashboardSurface.swift
//  Peakmon
//
//  Full-width dashboard shown when the top pill is on
//  `MainWindowTab.dashboard`: a system identity + health banner,
//  then a responsive 12-column Bento grid. Very wide windows use a
//  2:1:1 span (one information-dense card + two small cards), medium
//  windows use three equal columns, and narrow windows use two.
//  Processes always spans the full width below the metrics.
//
//  No page title at the top — the pill already reads "Dashboard";
//  repeating it in 34pt would waste a third of the first screen.
//

import PeakmonCore
import SwiftUI

struct DashboardSurface: View {
    let onShowHistory: (HistoryAnomalyEvent?) -> Void

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
        static let rowSpacing: CGFloat = 12
        static let horizontalPadding: CGFloat = 24
        static let topPadding: CGFloat = 12
        static let bottomPadding: CGFloat = 24

        /// Content-derived heights remove the large empty regions
        /// created by forcing every pair to match its tallest card.
        /// CPU keeps its E/P per-core band between the headline and
        /// footer, so it needs one additional compact detail slot.
        static let cpuHeight: CGFloat = 250
        static let memoryHeight: CGFloat = 220
        /// GPU keeps three power-rail rows below its headline.
        static let gpuHeight: CGFloat = 250
        /// Power needs a taller body than other compact cards: four
        /// rail rows sit above a reserved battery footer. Keeping the
        /// safe height prevents Display from crowding that footer.
        static let powerHeight: CGFloat = 270
        static let diskHeight: CGFloat = 220
        static let networkHeight: CGFloat = 210

        /// Keep the dashboard readable on ultrawide displays while
        /// allowing a full-screen window to use more of a standard
        /// desktop panel. The banner, metrics, and process table all
        /// share this width so they read as one centered workspace.
        static let contentMaximumWidth: CGFloat = 1_760
        static let bentoBreakpoint: CGFloat = 1_320
        static let threeColumnBreakpoint: CGFloat = 1_000

        /// Approximate fixed chrome used when sizing the process
        /// viewport. The live table consumes any remaining vertical
        /// room in a tall window instead of leaving a dead band below
        /// the dashboard. Compact windows retain a useful minimum and
        /// continue to scroll as before.
        static let systemBannerHeight: CGFloat = 58
        static let processPanelChromeHeight: CGFloat = 105
        static let minimumProcessScrollHeight: CGFloat = 320
        static let maximumProcessScrollHeight: CGFloat = 640

        /// Bento rows use one explicit height for every card in the
        /// row. Individual natural heights still drive the denser
        /// three/two-column layouts, but cannot create a vertical
        /// seam between stacked cards in the wide composition.
        static var bentoTopRowHeight: CGFloat {
            max(cpuHeight, memoryHeight, gpuHeight)
        }

        static var bentoBottomRowHeight: CGFloat {
            max(powerHeight, diskHeight, networkHeight)
        }

        static var bentoHeight: CGFloat {
            bentoTopRowHeight + rowSpacing + bentoBottomRowHeight
        }

        /// Equalise the three column totals against the dense
        /// Memory + Power column so every bottom card lands on the
        /// same baseline immediately above Processes.
        static var threeColumnContentHeight: CGFloat {
            memoryHeight + powerHeight
        }

        static var threeColumnNetworkHeight: CGFloat {
            max(networkHeight, threeColumnContentHeight - cpuHeight)
        }

        static var threeColumnDiskHeight: CGFloat {
            max(diskHeight, threeColumnContentHeight - gpuHeight)
        }

        static var threeColumnHeight: CGFloat {
            threeColumnContentHeight + rowSpacing
        }

        static var twoColumnNaturalLeftHeight: CGFloat {
            cpuHeight + gpuHeight + networkHeight
        }

        static var twoColumnNaturalRightHeight: CGFloat {
            memoryHeight + powerHeight + diskHeight
        }

        static var twoColumnContentHeight: CGFloat {
            max(twoColumnNaturalLeftHeight, twoColumnNaturalRightHeight)
        }

        static var twoColumnNetworkHeight: CGFloat {
            max(networkHeight, twoColumnContentHeight - cpuHeight - gpuHeight)
        }

        static var twoColumnDiskHeight: CGFloat {
            max(diskHeight, twoColumnContentHeight - memoryHeight - powerHeight)
        }

        static var twoColumnHeight: CGFloat {
            twoColumnContentHeight + rowSpacing * 2
        }

        static func metricsHeight(for width: CGFloat) -> CGFloat {
            if width >= bentoBreakpoint {
                bentoHeight
            } else if width >= threeColumnBreakpoint {
                threeColumnHeight
            } else {
                twoColumnHeight
            }
        }

        static func processScrollHeight(viewportHeight: CGFloat, metricsWidth: CGFloat) -> CGFloat {
            let fixedHeight = topPadding
                + bottomPadding
                + systemBannerHeight
                + rowSpacing * 2
                + metricsHeight(for: metricsWidth)
                + processPanelChromeHeight
            return min(
                maximumProcessScrollHeight,
                max(minimumProcessScrollHeight, viewportHeight - fixedHeight),
            )
        }
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
        GeometryReader { proxy in
            let availableWidth = max(0, proxy.size.width - Layout.horizontalPadding * 2)
            let contentWidth = min(availableWidth, Layout.contentMaximumWidth)

            ScrollView {
                // `LazyVStack` keeps off-screen cards out of the view
                // tree until they near the viewport, shrinking the
                // per-frame `DisplayList`. The eager `VStack` previously
                // forced all six cards + banner + process table into
                // every rasterise pass, making `render_contents`
                // dominate the main thread during scroll. Each card
                // rebuilds once on re-entry, but its data lives in the
                // shared `MetricsStore` so that's a cheap copy.
                LazyVStack(alignment: .center, spacing: Layout.rowSpacing) {
                    DashboardSystemBanner(onShowHistory: onShowHistory)
                        .frame(width: contentWidth)
                    dashboardGrid(
                        contentWidth: contentWidth,
                        viewportHeight: proxy.size.height,
                    )
                }
                .padding(.horizontal, Layout.horizontalPadding)
                .padding(.top, Layout.topPadding)
                .padding(.bottom, Layout.bottomPadding)
                .frame(maxWidth: .infinity, alignment: .top)
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
    }

    @ViewBuilder
    private func dashboardGrid(contentWidth: CGFloat, viewportHeight: CGFloat) -> some View {
        let showsProcesses = cardSettings.visibility(.processes)
        let processScrollHeight = Layout.processScrollHeight(
            viewportHeight: viewportHeight,
            metricsWidth: contentWidth,
        )

        LazyVStack(alignment: .center, spacing: Layout.rowSpacing) {
            if contentWidth >= Layout.bentoBreakpoint {
                bentoMetrics(width: contentWidth)
                    .frame(width: contentWidth, height: Layout.bentoHeight, alignment: .top)
            } else if contentWidth >= Layout.threeColumnBreakpoint {
                threeColumnMetrics
                    .frame(width: contentWidth, height: Layout.threeColumnHeight, alignment: .top)
            } else {
                twoColumnMetrics
                    .frame(width: contentWidth, height: Layout.twoColumnHeight, alignment: .top)
            }

            if showsProcesses {
                DashboardProcessesPanel(scrollHeight: processScrollHeight)
                    .frame(width: contentWidth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// 12-column desktop composition expressed as 6 / 3 / 3 spans.
    /// CPU and Power keep the width their per-core / per-rail detail
    /// earns; the four glanceable cards become compact quarter-width
    /// modules instead of stretching to half the dashboard.
    private func bentoMetrics(width: CGFloat) -> some View {
        let contentWidth = max(0, width - Layout.columnSpacing * 2)
        let largeWidth = contentWidth / 2
        let smallWidth = contentWidth / 4

        return VStack(spacing: Layout.rowSpacing) {
            HStack(alignment: .top, spacing: Layout.columnSpacing) {
                metricCard(height: Layout.bentoTopRowHeight, sizeClass: .hero) {
                    DashboardCPUCard()
                }
                .frame(width: largeWidth)

                metricCard(height: Layout.bentoTopRowHeight, sizeClass: .compact) {
                    DashboardMemoryCard()
                }
                .frame(width: smallWidth)

                metricCard(height: Layout.bentoTopRowHeight, sizeClass: .compact) {
                    DashboardGPUCard()
                }
                .frame(width: smallWidth)
            }
            .frame(height: Layout.bentoTopRowHeight, alignment: .top)

            HStack(alignment: .top, spacing: Layout.columnSpacing) {
                metricCard(height: Layout.bentoBottomRowHeight, sizeClass: .hero) {
                    DashboardPowerCard()
                }
                .frame(width: largeWidth)

                metricCard(height: Layout.bentoBottomRowHeight, sizeClass: .compact) {
                    DashboardDiskCard()
                }
                .frame(width: smallWidth)

                metricCard(height: Layout.bentoBottomRowHeight, sizeClass: .compact) {
                    DashboardNetworkCard()
                }
                .frame(width: smallWidth)
            }
            .frame(height: Layout.bentoBottomRowHeight, alignment: .top)
        }
    }

    private var threeColumnMetrics: some View {
        HStack(alignment: .top, spacing: Layout.columnSpacing) {
            LazyVStack(spacing: Layout.rowSpacing) {
                metricCard(height: Layout.cpuHeight, sizeClass: .regular) {
                    DashboardCPUCard()
                }
                metricCard(height: Layout.threeColumnNetworkHeight, sizeClass: .compact) {
                    DashboardNetworkCard()
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)

            LazyVStack(spacing: Layout.rowSpacing) {
                metricCard(height: Layout.memoryHeight, sizeClass: .compact) {
                    DashboardMemoryCard()
                }
                metricCard(height: Layout.powerHeight, sizeClass: .compact) {
                    DashboardPowerCard()
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)

            LazyVStack(spacing: Layout.rowSpacing) {
                metricCard(height: Layout.gpuHeight, sizeClass: .compact) {
                    DashboardGPUCard()
                }
                metricCard(height: Layout.threeColumnDiskHeight, sizeClass: .compact) {
                    DashboardDiskCard()
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var twoColumnMetrics: some View {
        HStack(alignment: .top, spacing: Layout.columnSpacing) {
            LazyVStack(spacing: Layout.rowSpacing) {
                metricCard(height: Layout.cpuHeight, sizeClass: .regular) {
                    DashboardCPUCard()
                }
                metricCard(height: Layout.gpuHeight, sizeClass: .regular) {
                    DashboardGPUCard()
                }
                metricCard(height: Layout.twoColumnNetworkHeight, sizeClass: .compact) {
                    DashboardNetworkCard()
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)

            LazyVStack(spacing: Layout.rowSpacing) {
                metricCard(height: Layout.memoryHeight, sizeClass: .regular) {
                    DashboardMemoryCard()
                }
                metricCard(height: Layout.powerHeight, sizeClass: .regular) {
                    DashboardPowerCard()
                }
                metricCard(height: Layout.twoColumnDiskHeight, sizeClass: .compact) {
                    DashboardDiskCard()
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func metricCard<Content: View>(
        height: CGFloat,
        sizeClass: DashboardCardSizeClass,
        @ViewBuilder content: () -> Content,
    ) -> some View {
        content()
            .environment(\.dashboardCardTargetHeight, height)
            .environment(\.dashboardCardSizeClass, sizeClass)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: height, alignment: .topLeading)
            .clipped()
    }

}
