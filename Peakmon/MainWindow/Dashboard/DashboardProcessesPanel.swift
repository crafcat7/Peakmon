//
//  DashboardProcessesPanel.swift
//  Peakmon
//
//  Full-width "Processes" table at the bottom of the metric grid.
//  Rows are *applications*, not individual PIDs: `ProcessGrouping`
//  folds every PID of one `.app` bundle (Chrome's helpers, Xcode's
//  XPC services, …) into one aggregate row. Bundle-less daemons /
//  kernel tasks stay as their own rows.
//
//  Columns: APPLICATION / PIDS / CPU% / MEM. Clicking a column
//  header sorts by it (re-click flips direction). Clicking a row
//  selects it; clicking the selected row opens `ProcessDetailSheet`.
//

import AppKit
import PeakmonCore
import PeakmonUI
import SwiftUI

struct DashboardProcessesPanel: View {
    @Environment(ProcessesStore.self) private var processesStore
    @Environment(\.cardSettings) private var cardSettings

    @State private var sortKey: ProcessGrouping.GroupSortKey = .cpu

    /// Sort direction for the active column. Defaults to descending
    /// ("what's eating my machine"); the active header flips it.
    @State private var sortAscending = false

    /// Group whose detail sheet is open, or nil.
    @State private var inspecting: ProcessGroup?

    /// Selected row id. First click selects/highlights; clicking the
    /// already-selected row opens its detail sheet.
    @State private var selectedID: ProcessGroup.ID?

    /// Supplied by the dashboard viewport. Tall/full-screen windows
    /// reveal more rows; compact windows keep a stable minimum and
    /// let the outer dashboard scroll.
    let scrollHeight: CGFloat

    init(scrollHeight: CGFloat = 320) {
        self.scrollHeight = scrollHeight
    }

    private var tint: Color { cardSettings.tint(.processes) }

    var body: some View {
        // Group once per body pass and pass plain locals down. A
        // prior computed-property design caused N² grouping per tick
        // (once for the header, once per row via `maxCPU`); one pass
        // is correct and the data can't be cached across ticks since
        // `cpuPercent` changes every store tick.
        let groups = ProcessGrouping.group(processesStore.latestProcesses, sortedBy: sortKey, ascending: sortAscending)
        let maxCPU = max(groups.map(\.totalCPU).max() ?? 100, 1)

        return VStack(alignment: .leading, spacing: 12) {
            header(groupCount: groups.count, processCount: processesStore.latestProcesses.count)
            tableBody(groups: groups, maxCPU: maxCPU)
        }
        .padding(20)
        .peakmonGlassSurface()
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.gray.opacity(0.18), lineWidth: 0.5),
        )
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
        .sheet(item: $inspecting) { g in
            ProcessDetailSheet(group: g) {
                inspecting = nil
            }
        }
    }

    private func header(groupCount: Int, processCount: Int) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(tint.opacity(0.13), in: .rect(cornerRadius: 5))
            Text("PROCESSES")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.55)
            Spacer()
            Text("\(groupCount) apps · \(processCount) processes · sorted by \(sortKey == .cpu ? "CPU%" : "Memory")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func tableBody(groups: [ProcessGroup], maxCPU: Double) -> some View {
        VStack(spacing: 0) {
            columnHeader
            Divider().opacity(0.4)
            if groups.isEmpty {
                Text("Collecting process data…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 32)
                    .frame(height: scrollHeight, alignment: .topLeading)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { idx, g in
                            row(g, maxCPU: maxCPU)
                                .background(rowBackground(id: g.id, index: idx))
                        }
                    }
                }
                .frame(height: scrollHeight)
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 12) {
            Text("APPLICATION")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("PIDS")
                .frame(width: 110, alignment: .trailing)
            sortableHeader(label: "CPU%", key: .cpu, width: 220)
            sortableHeader(label: "MEM", key: .memory, width: 100)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }

    private func sortableHeader(label: String, key: ProcessGrouping.GroupSortKey, width: CGFloat)
        -> some View
    {
        Button {
            if sortKey == key {
                sortAscending.toggle()
            } else {
                sortKey = key
                sortAscending = false
            }
        } label: {
            HStack(spacing: 4) {
                if sortKey == key {
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.primary)
                }
                Text(label)
                    .foregroundStyle(sortKey == key ? .primary : .tertiary)
            }
            .frame(width: width, alignment: .trailing)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Sort by \(label)")
    }

    private func row(_ g: ProcessGroup, maxCPU: Double) -> some View {
        // A `Button`, not `.onTapGesture`: inside a ScrollView a bare
        // tap gesture competes with the scroll drag recognizer and
        // fires only after a recognition delay, feeling laggy. A
        // button's click dispatches immediately. `.plain` keeps the
        // row visuals untouched.
        Button {
            if selectedID == g.id {
                inspecting = g
            } else {
                selectedID = g.id
            }
        } label: {
            rowContent(g, maxCPU: maxCPU)
        }
        .buttonStyle(.plain)
    }

    private func rowContent(_ g: ProcessGroup, maxCPU: Double) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                appIcon(for: g)
                    .frame(width: 18, height: 18)
                Text(g.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if g.children.count > 1 {
                    Text("\(g.children.count)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.secondary.opacity(0.15), in: .capsule)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Representative PID = the heaviest child; the full set
            // is one click away in the detail sheet.
            Text("\(g.children[0].pid)\(g.children.count > 1 ? " +\(g.children.count - 1)" : "")")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)

            cpuCell(g.totalCPU, maxCPU: maxCPU)
                .frame(width: 220, alignment: .trailing)

            Text(DashboardFormatting.bytesShort(Double(g.totalMemory)))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .contentShape(.rect)
    }

    /// Tinted highlight for the selected row, else a zebra stripe.
    private func rowBackground(id: ProcessGroup.ID, index: Int) -> Color {
        if selectedID == id {
            return Color.accentColor.opacity(0.18)
        }
        return index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.03)
    }

    /// Real bundle icon for .app groups; SF Symbol fallback for
    /// daemons and kernel tasks. Icons are cached per bundle path
    /// (see `AppIconCache`) to keep the per-row lookup off
    /// NSWorkspace.
    @ViewBuilder
    private func appIcon(for g: ProcessGroup) -> some View {
        if !g.bundlePath.isEmpty {
            Image(nsImage: AppIconCache.shared.icon(forBundleAt: g.bundlePath))
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 18, height: 18)
        }
    }

    /// CPU column = horizontal bar (share of the busiest group's
    /// CPU%) + numeric value at the right edge.
    private func cpuCell(_ cpu: Double, maxCPU: Double) -> some View {
        HStack(spacing: 8) {
            GeometryReader { proxy in
                let ratio = min(1, max(0, cpu / maxCPU))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 6)
                    Capsule()
                        .fill(DashboardFormatting.cpuTint(cpu).gradient)
                        .frame(width: proxy.size.width * ratio, height: 6)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 14)

            Text(String(format: "%.1f%%", cpu))
                .font(.callout.monospacedDigit())
                .foregroundStyle(DashboardFormatting.cpuTint(cpu))
                .frame(width: 66, alignment: .trailing)
        }
    }

}

/// Process-wide cache of bundle path → NSImage. Bundle icons are
/// stable for the process lifetime, so entries are never evicted.
private final class AppIconCache {
    static let shared = AppIconCache()
    private let lock = NSLock()
    private var storage: [String: NSImage] = [:]

    func icon(forBundleAt path: String) -> NSImage {
        lock.lock()
        if let cached = storage[path] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Hit NSWorkspace outside the lock: first access can be slow,
        // and serialising misses would penalise unrelated rows.
        let image = NSWorkspace.shared.icon(forFile: path)
        lock.lock()
        storage[path] = image
        lock.unlock()
        return image
    }
}
