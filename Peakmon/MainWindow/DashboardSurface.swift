//
//  DashboardSurface.swift
//  Peakmon
//
//  Full-width dashboard rendered inside the unified main window
//  when the top pill is on `MainWindowTab.dashboard`.
//
//  Layout: pure `LazyVGrid` of `DashboardXxxCard` panels — no
//  hero strip, no category sections. Each card is independently
//  collapsible/expandable (inline drill-down) so the user
//  controls density per-domain rather than the surface forcing
//  a uniform information shape.
//
//  v1.3 D2.1 ships the CPU card first to lock the visual /
//  interaction template; D2.2 batches Memory/Disk/Network/GPU/
//  Power. Hero rings were prototyped in an earlier D2.1 draft
//  and deliberately dropped — they ate vertical real-estate
//  without surfacing anything the cards themselves can't carry.
//
//  The page title is intentionally NOT printed at the top — the
//  top pill already reads "Dashboard". Duplicating it in 34pt
//  immediately below would waste a third of the first screen.
//

import PeakmonCore
import SwiftUI

struct DashboardSurface: View {
    @Environment(MetricsStore.self) private var store

    /// Single `LazyVGrid` column descriptor. `.adaptive(minimum:)`
    /// lets the dashboard reflow naturally between 880pt (1 col),
    /// ~1280pt (2 cols), and ultra-wide displays (3 cols) without
    /// fixed breakpoint logic. 420pt minimum chosen to keep the
    /// CPU card's 36pt headline + 200pt trend chart comfortable.
    private let columns = [
        GridItem(.adaptive(minimum: 420, maximum: .infinity), spacing: 16, alignment: .top),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    DashboardCPUCard()
                    // D2.2: DashboardMemoryCard, DashboardDiskCard,
                    // DashboardNetworkCard, DashboardGPUCard,
                    // DashboardPowerCard land here.
                }
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
}
