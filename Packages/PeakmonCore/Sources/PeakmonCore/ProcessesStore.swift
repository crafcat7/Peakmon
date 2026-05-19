//
//  ProcessesStore.swift
//  PeakmonCore
//
//  Dedicated observable buffer for `ProcessSnapshot` lists.
//
//  Lives in a separate type from `MetricsStore` on purpose: `@Observable`
//  invalidates SwiftUI dependents at the *class* granularity in practice
//  (writing any tracked property fires the underlying didSet on the
//  shared observation registry, so any view reading any property on the
//  same instance gets re-evaluated). The Top Processes feature samples
//  at 0.5 Hz and produces a fresh array every tick — folding that into
//  `MetricsStore` was observed to force `MenuBarLabel.ImageRenderer` to
//  re-rasterise on every process tick, pushing steady-state CPU from
//  ~0 % to ~50 %.
//
//  Keeping processes in their own observable means only views that
//  *actually* read `latestProcesses` (the Top Processes card) re-render
//  when the snapshot list updates. The menu-bar label and every other
//  metric card remain on the `MetricsStore` invalidation graph and
//  stay completely undisturbed.
//

import Foundation
import Observation

@MainActor
@Observable
public final class ProcessesStore {
    /// Most recent process snapshot batch (already sorted descending
    /// by whatever ranking the producer chose — typically CPU%). The
    /// Top Processes card reads this directly.
    public private(set) var latestProcesses: [ProcessSnapshot] = []

    public init() {}

    /// Replace the most recent process snapshot list. Producer is
    /// expected to pre-sort and pre-limit so the store does not have
    /// to know about ranking policy.
    public func ingest(_ processes: [ProcessSnapshot]) {
        latestProcesses = processes
    }

    /// Drop the retained snapshot, e.g. after the user disables the
    /// Top Processes card so stale rows do not flash back in when
    /// the popover re-opens.
    public func clear() {
        if latestProcesses.isEmpty { return }
        latestProcesses = []
    }
}
