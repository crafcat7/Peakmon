//
//  DashboardProcessesPanel.swift
//  Peakmon
//
//  Full-width "Processes" table at the bottom of the dashboard,
//  after the metric card cluster. Rows are *applications*, not
//  individual PIDs: `ProcessGrouping` folds all the PIDs that
//  belong to one `.app` bundle (Chrome's renderer / GPU /
//  utility helpers, Xcode's many XPC services, etc.) into a
//  single row showing the aggregate CPU and memory of the
//  whole app. Daemons / kernel tasks with no bundle remain as
//  their own rows.
//
//  Columns: NAME (with bundle icon + child-count badge) / PIDS
//  (representative + count) / CPU% (aggregate, with bar) / MEM
//  (aggregate). Clicking CPU% or MEM toggles the sort key.
//  Double-clicking a row pops `ProcessDetailSheet` for the
//  group so the user can drill in to per-child path / args /
//  threads.
//

import AppKit
import PeakmonCore
import SwiftUI

struct DashboardProcessesPanel: View {
    @Environment(ProcessesStore.self) private var processesStore

    @State private var sortKey: ProcessGrouping.GroupSortKey = .cpu

    /// Sort direction for the active column. Defaults to descending
    /// (heaviest first) since "what's eating my machine" is the
    /// common question; clicking the active column header flips it.
    @State private var sortAscending = false

    /// Double-clicked group, drives the detail sheet. Nil = no
    /// sheet presented; non-nil = sheet open over `group`.
    @State private var inspecting: ProcessGroup?

    /// Currently selected row id. A first single-click selects and
    /// highlights a row; a second single-click on the already-
    /// selected row opens its detail sheet. Double-click still
    /// opens directly without the intermediate select step.
    @State private var selectedID: ProcessGroup.ID?

    /// Fixed scroller height keeps the panel's footprint constant
    /// so the dashboard total height doesn't twitch as the app
    /// count changes.
    private let scrollHeight: CGFloat = 440

    var body: some View {
        // Recompute grouping exactly once per body pass and pass
        // the result down as plain local values. The previous
        // computed-property design caused N² grouping calls per
        // tick (one for `groups` in the header, one per row via
        // `maxCPU`). One pass per tick is correct *and* keeps
        // the data fresh — `cpuPercent` updates every store
        // tick, so we can't cache across ticks anyway.
        let groups = ProcessGrouping.group(processesStore.latestProcesses, sortedBy: sortKey, ascending: sortAscending)
        let maxCPU = max(groups.map(\.totalCPU).max() ?? 100, 1)

        return VStack(alignment: .leading, spacing: 12) {
            header(groupCount: groups.count, processCount: processesStore.latestProcesses.count)
            tableBody(groups: groups, maxCPU: maxCPU)
        }
        .padding(20)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.gray.opacity(0.18), lineWidth: 0.5),
        )
        .clipShape(.rect(cornerRadius: 14))
        .sheet(item: $inspecting) { g in
            ProcessDetailSheet(group: g) {
                inspecting = nil
            }
        }
    }

    private func header(groupCount: Int, processCount: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(7)
                .background(.primary.opacity(0.08), in: .rect(cornerRadius: 7))
            Text("Processes")
                .font(.headline)
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
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { idx, g in
                            row(g, maxCPU: maxCPU)
                                .background(rowBackground(id: g.id, index: idx))
                        }
                    }
                }
                .frame(maxHeight: scrollHeight)
            }
        }
    }

    /// Column header. CPU% and MEM are buttons (rendered as plain
    /// styled text) so clicking either toggles the active sort key.
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
                // Re-clicking the active column flips direction.
                sortAscending.toggle()
            } else {
                // Switching columns selects it fresh, descending.
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
        // Wrapped in a Button rather than `.onTapGesture` because a
        // bare tap gesture inside a ScrollView competes with the
        // scroll drag recognizer, so every click waited out a
        // recognition window before firing and felt laggy. A
        // Button's click is dispatched immediately. `.plain` style
        // keeps the row visuals untouched (no default button
        // chrome / highlight).
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

            // Representative PID = the heaviest child. The full set
            // is one click away in the detail sheet, so showing the
            // "leader" PID here is enough to anchor the row.
            Text("\(g.children[0].pid)\(g.children.count > 1 ? " +\(g.children.count - 1)" : "")")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)

            cpuCell(g.totalCPU, maxCPU: maxCPU)
                .frame(width: 220, alignment: .trailing)

            Text(formatBytes(g.totalMemory))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .contentShape(.rect)
    }

    /// Row background: tint-tinted highlight for the selected row,
    /// otherwise the subtle zebra stripe on odd rows.
    private func rowBackground(id: ProcessGroup.ID, index: Int) -> Color {
        if selectedID == id {
            return Color.accentColor.opacity(0.18)
        }
        return index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.03)
    }

    /// Real bundle icon for .app groups; SF Symbol fallback for
    /// daemons and kernel tasks.
    ///
    /// `NSWorkspace.icon(forFile:)` has its own in-process cache,
    /// but the wrapping `Image(nsImage:)` still allocates a new
    /// SwiftUI image view per row per tick. We additionally keep
    /// our own bundle-path → NSImage map so the per-row lookup
    /// hits a dictionary instead of crossing into NSWorkspace.
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

    /// CPU column = horizontal bar (proportional to the row's
    /// share of the busiest group's CPU%) + numeric value at the
    /// right edge.
    private func cpuCell(_ cpu: Double, maxCPU: Double) -> some View {
        HStack(spacing: 8) {
            GeometryReader { proxy in
                let ratio = min(1, max(0, cpu / maxCPU))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 6)
                    Capsule()
                        .fill(barTint(cpu).gradient)
                        .frame(width: proxy.size.width * ratio, height: 6)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 14)

            Text(String(format: "%.1f%%", cpu))
                .font(.callout.monospacedDigit())
                .foregroundStyle(barTint(cpu))
                .frame(width: 66, alignment: .trailing)
        }
    }

    private func barTint(_ cpu: Double) -> Color {
        if cpu < 10 { return .secondary }
        if cpu < 50 { return .primary }
        if cpu < 150 { return .orange }
        return .red
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.0f MB", mb)
    }
}

#Preview {
    DashboardProcessesPanel()
        .frame(width: 1000, height: 500)
        .padding()
        .environment(ProcessesStore())
}

/// Process-wide cache of bundle path → NSImage. Bundle icons
/// don't change for the life of the process, so we never
/// invalidate. The wrapper exists purely to centralise the
/// `NSWorkspace.shared.icon(forFile:)` call and dedupe per
/// bundle path.
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

        // Hit NSWorkspace outside the lock — it can be slow on
        // first access for unusual bundles, and serialising all
        // misses would penalise unrelated rows.
        let image = NSWorkspace.shared.icon(forFile: path)
        lock.lock()
        storage[path] = image
        lock.unlock()
        return image
    }
}
