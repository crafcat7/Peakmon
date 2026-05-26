//
//  DashboardSurface.swift
//  Peakmon
//
//  Full-width dashboard rendered inside the unified main window
//  when the top pill is on `MainWindowTab.dashboard`.
//
//  D1 v2 ships this as a deliberately minimal placeholder so the
//  navigation structure (Window("main") + floating top pill +
//  Dashboard/Settings detail swap) can be validated end-to-end
//  before the real KPI grid lands in D2.
//
//  The page title is intentionally NOT printed at the top — the
//  top pill already says "Dashboard", and duplicating it in 34pt
//  immediately below clutters the page chrome. Only the small
//  live-indicator pill remains, right-aligned, leaving the centre
//  of the page reserved for D2's card grid.
//

import PeakmonCore
import SwiftUI

struct DashboardSurface: View {
    @Environment(MetricsStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                placeholderBody
                    .padding(.horizontal, 20)
            }
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// Placeholder body shown until the D2 KPI grid lands. Reads
    /// no `store.*` property beyond the warming flag in `header`,
    /// so the page does not subscribe to every metric tick while
    /// it is still functionally empty.
    private var placeholderBody: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)
            Text("Dashboard grid coming next")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text("D2 will fill this surface with the existing CPU, Memory, Battery, Disk, Network, Processes, GPU, and Power cards.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

#Preview {
    DashboardSurface()
        .frame(width: 880, height: 600)
        .environment(MetricsStore())
}
