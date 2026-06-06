//
//  ProcessDetailSheet.swift
//  Peakmon
//
//  Modal sheet opened from a row in the dashboard's Processes
//  panel. The panel groups by `.app` bundle, so this sheet operates
//  on a `ProcessGroup`, not a single snapshot.
//
//    • Hero header — bundle icon, name, aggregate chips.
//    • Child-process table — every PID in the group, CPU-ranked;
//      clicking a row focuses it (heaviest is focused on open).
//    • Detail strip — path / args / Mach threads of the focused
//      PID, reloaded asynchronously when focus changes.
//
//  `ProcessDetailReader.read(pid:)` runs in a detached `Task` on
//  focus change. The reader is `nonisolated` so it never bounces
//  the main actor; cross-user PIDs return empty path/args, which
//  render as explicit "unavailable" placeholders.
//

import AppKit
import PeakmonCore
import SwiftUI

struct ProcessDetailSheet: View {
    let group: ProcessGroup
    let onDismiss: () -> Void

    /// Which child the lower strip describes. Starts at the
    /// heaviest (index 0 from `ProcessGrouping` sorting); changing
    /// it triggers a fresh `ProcessDetailReader.read(pid:)`.
    @State private var focusedPID: Int32

    /// Detail blob for `focusedPID`, nil while a load is in flight.
    @State private var detail: ProcessDetail?

    /// Bundle icon, resolved once on appear.
    @State private var appIcon: NSImage?

    init(group: ProcessGroup, onDismiss: @escaping () -> Void) {
        self.group = group
        self.onDismiss = onDismiss
        _focusedPID = State(initialValue: group.children[0].pid)
    }

    /// The focused child, recomputed each render so a future "live"
    /// mode (refreshing the group while open) drops straight in.
    private var focusedChild: ProcessSnapshot {
        group.children.first(where: { $0.pid == focusedPID }) ?? group.children[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroHeader
            Divider().opacity(0.5)
            // Child list on top, focused-PID detail strip below;
            // one scrollview so the sheet keeps its fixed height.
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    childrenSection
                    pathSection
                    argsSection
                    threadsSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 820, height: 680)
        .background(.background)
        .task(id: focusedPID) {
            // Reload detail on focus change at background priority;
            // wipe old detail to avoid flashing the previous PID's.
            detail = nil
            let pid = focusedPID
            let built = await Task.detached(priority: .userInitiated) {
                ProcessDetailReader.read(pid: pid)
            }.value
            // Discard if focus changed again while loading.
            if pid == focusedPID {
                detail = built
            }
        }
        .task {
            if !group.bundlePath.isEmpty {
                appIcon = NSWorkspace.shared.icon(forFile: group.bundlePath)
            } else if !focusedChild.path.isEmpty {
                appIcon = NSWorkspace.shared.icon(forFile: focusedChild.path)
            }
        }
    }

    // MARK: - Hero header

    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                iconView
                    .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 4) {
                    Text(group.displayName)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(headerSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(.secondary.opacity(0.15), in: .circle)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
            }

            chipsRow
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .background(.background.secondary)
    }

    /// "12 processes · Focused PID 1234" or, for single-child
    /// groups, just "PID 1234".
    private var headerSubtitle: String {
        if group.children.count == 1 {
            return "PID \(focusedPID)"
        }
        return "\(group.children.count) processes · Focused PID \(focusedPID)"
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon = appIcon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.tint.opacity(0.15))
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.tint)
            }
        }
    }

    private var chipsRow: some View {
        HStack(spacing: 8) {
            metricChip(icon: "cpu",
                       label: "CPU",
                       value: String(format: "%.1f%%", group.totalCPU),
                       tint: DashboardFormatting.cpuTint(group.totalCPU))
            metricChip(icon: "memorychip",
                       label: "Memory",
                       value: DashboardFormatting.bytesShort(Double(group.totalMemory)),
                       tint: .blue)
            metricChip(icon: "square.stack.3d.up",
                       label: "Processes",
                       value: String(group.children.count),
                       tint: .purple)
            metricChip(icon: "rectangle.stack",
                       label: "Threads",
                       value: detail.map { String($0.threads.count) } ?? "…",
                       tint: .indigo)
            metricChip(icon: "clock",
                       label: "Started",
                       value: detail?.startedAt.map(formatStart) ?? "…",
                       tint: .orange)
            Spacer()
        }
    }

    private func metricChip(icon: String, label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.10), in: .capsule)
        .overlay(
            Capsule().strokeBorder(tint.opacity(0.15), lineWidth: 0.5),
        )
    }

    // MARK: - Section header

    private func sectionHeader(_ title: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
        }
    }

    // MARK: - Children table

    /// Every PID in the group; clicking a row focuses it for the
    /// path/args/threads strip below, with a tinted focused row.
    private var childrenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sectionHeader("Processes in this app", systemImage: "square.stack.3d.up", tint: .purple)
            }

            VStack(spacing: 0) {
                childrenHeaderRow
                Divider().opacity(0.4)
                ForEach(Array(group.children.enumerated()), id: \.element.id) { idx, child in
                    childRow(child, zebra: !idx.isMultiple(of: 2))
                }
            }
            .background(.background.tertiary, in: .rect(cornerRadius: 10))
            .clipShape(.rect(cornerRadius: 10))
        }
    }

    private var childrenHeaderRow: some View {
        HStack(spacing: 10) {
            Text("PID")
                .frame(width: 70, alignment: .leading)
            Text("PPID")
                .frame(width: 70, alignment: .leading)
            Text("NAME")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("CPU%")
                .frame(width: 80, alignment: .trailing)
            Text("MEM")
                .frame(width: 90, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
    }

    private func childRow(_ child: ProcessSnapshot, zebra: Bool) -> some View {
        let isFocused = child.pid == focusedPID
        // Button (not onTapGesture) so the tap never competes with the
        // enclosing ScrollView's drag — see DashboardProcessesPanel.
        return Button {
            focusedPID = child.pid
        } label: {
            HStack(spacing: 10) {
                Text(String(child.pid))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(isFocused ? .primary : .secondary)
                    .frame(width: 70, alignment: .leading)
                Text(child.ppid > 0 ? String(child.ppid) : "—")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 70, alignment: .leading)
                Text(child.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isFocused ? Color.primary : Color.primary.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(String(format: "%.1f%%", child.cpuPercent))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(DashboardFormatting.cpuTint(child.cpuPercent))
                    .frame(width: 80, alignment: .trailing)
                Text(DashboardFormatting.bytesShort(Double(child.memoryBytes)))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .trailing)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 14)
            .background(
                // Tinted underlay marks the row the detail strip is
                // describing.
                isFocused
                    ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                    : AnyShapeStyle(zebra ? Color.primary.opacity(0.025) : Color.clear),
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Path

    private var pathSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Executable Path", systemImage: "folder.fill", tint: .blue)
            if let p = detail?.path, !p.isEmpty {
                HStack(spacing: 10) {
                    Text(p)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        revealInFinder(p)
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")

                    Button {
                        copyToPasteboard(p)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy path")
                }
                .padding(12)
                .background(.background.tertiary, in: .rect(cornerRadius: 10))
            } else {
                placeholder(detail == nil ? "Loading…" : "Path unavailable (cross-user or kernel process)")
            }
        }
    }

    // MARK: - Args

    private var argsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Arguments", systemImage: "chevron.left.forwardslash.chevron.right", tint: .green)
            if let args = detail?.args, !args.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(args.enumerated()), id: \.offset) { idx, arg in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(idx)")
                                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .frame(width: 24, alignment: .trailing)
                            Text(arg)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(12)
                .background(.background.tertiary, in: .rect(cornerRadius: 10))
            } else {
                placeholder(detail == nil ? "Loading…" : "Arguments unavailable (cross-user process)")
            }
        }
    }

    // MARK: - Threads

    private var threadsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sectionHeader("Mach Threads", systemImage: "rectangle.stack.fill", tint: .indigo)
                if let t = detail?.threads, !t.isEmpty {
                    Text("\(t.count)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.indigo)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.indigo.opacity(0.12), in: .capsule)
                }
            }

            if let threads = detail?.threads, !threads.isEmpty {
                VStack(spacing: 0) {
                    threadHeaderRow
                    Divider().opacity(0.4)
                    ForEach(Array(threads.enumerated()), id: \.element.id) { idx, t in
                        threadRow(t)
                            .background(idx.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025))
                    }
                }
                .background(.background.tertiary, in: .rect(cornerRadius: 10))
                .clipShape(.rect(cornerRadius: 10))
            } else {
                placeholder(detail == nil ? "Loading…" : "No thread info")
            }
        }
    }

    private var threadHeaderRow: some View {
        HStack(spacing: 10) {
            Text("TID")
                .frame(width: 92, alignment: .leading)
            Text("NAME")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("STATE")
                .frame(width: 110, alignment: .leading)
            Text("USER ms")
                .frame(width: 80, alignment: .trailing)
            Text("SYS ms")
                .frame(width: 80, alignment: .trailing)
            Text("PRI")
                .frame(width: 40, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 9)
        .padding(.horizontal, 14)
    }

    private func threadRow(_ t: ThreadInfo) -> some View {
        HStack(spacing: 10) {
            Text(String(t.id))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(t.name.isEmpty ? "—" : t.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(t.name.isEmpty ? .tertiary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Circle()
                    .fill(runStateColor(t.runState))
                    .frame(width: 6, height: 6)
                Text(t.runStateLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.primary)
            }
            .frame(width: 110, alignment: .leading)
            Text(String(t.cpuUserMs))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(String(t.cpuSystemMs))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(String(t.priority))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 6)
        .padding(.horizontal, 14)
    }

    // MARK: - Helpers

    private func placeholder(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.tertiary, in: .rect(cornerRadius: 10))
    }

    private func runStateColor(_ state: Int32) -> Color {
        switch state {
        case 1: return .green
        case 3: return .secondary
        case 2, 5: return .orange
        case 4: return .red
        default: return .secondary
        }
    }

    private func formatStart(_ d: Date) -> String {
        let f = DateFormatter()
        if Calendar.current.isDateInToday(d) {
            f.dateStyle = .none
            f.timeStyle = .short
        } else {
            f.dateStyle = .short
            f.timeStyle = .short
        }
        return f.string(from: d)
    }

    private func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func revealInFinder(_ path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
