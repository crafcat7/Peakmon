//
//  MetricsStore.swift
//  PeakmonCore
//
//  In-memory ring buffer of recent `MetricSample`s, observable from
//  SwiftUI. Storage of long-term history is the job of
//  `PeakmonStorage` (v0.2); this type only keeps a rolling window so the
//  UI can render the menu bar title and dashboard sparkline.
//

import Foundation
import Observation

/// Observable, MainActor-bound buffer of the latest samples per metric.
///
/// - `latest(for:)` returns the most recent value or `nil` if the
///   collector for that kind hasn't produced anything yet.
/// - `history(for:)` returns the window in oldest-first order, capped at
///   `historyLimit` entries per kind.
@MainActor
@Observable
public final class MetricsStore {
    /// Maximum number of samples retained per `MetricKind`.
    public let historyLimit: Int

    private var samples: [MetricKind: [MetricSample]] = [:]

    public init(historyLimit: Int = 120) {
        precondition(historyLimit > 0, "historyLimit must be positive")
        self.historyLimit = historyLimit
    }

    /// Append a batch of samples, trimming to the rolling window.
    ///
    /// Uses the in-place subscript `samples[kind, default: []]` so the
    /// underlying `Array` is mutated through Swift's `_modify`
    /// accessor instead of being copied out, mutated, and written
    /// back — that pattern triggers a buffer reassignment on every
    /// ingest tick, which in turn forces SwiftUI to treat the
    /// `history(for:)` result as a fresh array on every popover body
    /// pass. Trim cost is the steady-state minimum: a single
    /// `removeFirst()` per overflow rather than `removeFirst(n)`'s
    /// arithmetic + range path, since at the 1 Hz cadence overflow
    /// is always exactly one element.
    public func ingest(_ batch: [MetricSample]) {
        guard !batch.isEmpty else { return }
        for sample in batch {
            samples[sample.kind, default: []].append(sample)
            while samples[sample.kind]!.count > historyLimit {
                samples[sample.kind]!.removeFirst()
            }
        }
    }

    /// Most recent sample for `kind`, or `nil` if none yet.
    public func latest(for kind: MetricKind) -> MetricSample? {
        samples[kind]?.last
    }

    /// Rolling window for `kind`, oldest first.
    public func history(for kind: MetricKind) -> [MetricSample] {
        samples[kind] ?? []
    }

    /// Drop all retained samples. Primarily useful in tests.
    public func reset() {
        samples.removeAll(keepingCapacity: true)
    }
}
