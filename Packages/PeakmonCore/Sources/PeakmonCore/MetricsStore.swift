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
///   collector for that kind hasn't produced anything yet or reported
///   that its current reading is unavailable.
/// - `history(for:)` returns the window in oldest-first order, capped at
///   `historyLimit` entries per kind.
@MainActor
@Observable
public final class MetricsStore {
    /// Maximum number of samples retained per `MetricKind`.
    public let historyLimit: Int

    /// One fixed-capacity ring per metric kind. Each ring is lazily
    /// instantiated on the first ingest for that kind so we don't
    /// pre-allocate `MetricKind.allCases × historyLimit` slots up
    /// front for kinds the user's machine never produces (e.g. fan
    /// keys on a fanless MacBook Air).
    private var rings: [MetricKind: MetricRingBuffer] = [:]
    private var unavailableKinds: Set<MetricKind> = []

    public init(historyLimit: Int = 120) {
        precondition(historyLimit > 0, "historyLimit must be positive")
        self.historyLimit = historyLimit
    }

    /// Append a batch of samples to per-kind ring buffers.
    ///
    /// Each ring is fixed-capacity, so both append and overflow
    /// eviction are O(1) regardless of `historyLimit`. The previous
    /// `Array.removeFirst()`-based implementation was O(n) per
    /// overflow, which became measurable at the 1-hour /
    /// 3600-sample window the v1.3 dashboard requires.
    ///
    /// `Dictionary` subscript-with-default still triggers a COW
    /// roundtrip on the ring value, but the ring itself only owns a
    /// `ContiguousArray` header and indices — copying it is bounded
    /// by header size, not by sample count.
    public func ingest(_ batch: [MetricSample]) {
        guard !batch.isEmpty else { return }
        for sample in batch {
            guard sample.isAvailable else {
                unavailableKinds.insert(sample.kind)
                continue
            }
            unavailableKinds.remove(sample.kind)
            var ring = rings[sample.kind] ?? MetricRingBuffer(capacity: historyLimit)
            ring.append(sample)
            rings[sample.kind] = ring
        }
    }

    /// Most recent sample for `kind`, or `nil` if none yet or unavailable.
    public func latest(for kind: MetricKind) -> MetricSample? {
        guard !unavailableKinds.contains(kind) else { return nil }
        return rings[kind]?.last
    }

    /// Most recent sample when it is still fresh enough for a live surface.
    /// History remains available even after a value becomes stale.
    public func latest(
        for kind: MetricKind,
        maximumAge: TimeInterval,
        at now: Date = .now,
    ) -> MetricSample? {
        guard maximumAge.isFinite, maximumAge >= 0,
              let sample = latest(for: kind)
        else { return nil }
        let age = now.timeIntervalSince(sample.timestamp)
        guard age.isFinite, age <= maximumAge else { return nil }
        return sample
    }

    /// `true` when at least one sample has been ingested for `kind`.
    /// O(1) — avoids materialising the full history array that
    /// `history(for:).isEmpty` would create.
    public func hasHistory(for kind: MetricKind) -> Bool {
        (rings[kind]?.count ?? 0) > 0
    }

    /// Rolling window for `kind`, limited to at most `limit` entries,
    /// oldest first.
    ///
    /// This avoids materializing the full history when only a small
    /// suffix is required (e.g. menu-bar mini charts). Pass a
    /// positive `limit`; non-positive values return `[]`.
    public func historySuffix(for kind: MetricKind, limit: Int) -> [MetricSample] {
        guard limit > 0 else { return [] }
        return rings[kind]?.suffix(limit) ?? []
    }

    /// Most recent numeric value for `kind`, or `fallback` if none.
    ///
    /// Convenience wrapper used throughout the dashboard and menu-bar
    /// rasteriser, where `store.latest(for: .x)?.value ?? 0` was
    /// repeated upwards of 30 times. Centralising the unwrap keeps
    /// `kind` and the fallback obviously paired and makes
    /// negative-sentinel callers (`-1`) easier to spot.
    public func value(for kind: MetricKind, default fallback: Double = 0) -> Double {
        latest(for: kind)?.value ?? fallback
    }

    /// Rolling window for `kind`, oldest first.
    ///
    /// Materialises a fresh `[MetricSample]` per call. This is the
    /// one O(n) operation in the hot path; callers that re-render
    /// many times per second (the menu-bar rasteriser, SwiftUI
    /// Charts) already iterate the full window anyway, so the
    /// allocation is amortised.
    public func history(for kind: MetricKind) -> [MetricSample] {
        rings[kind]?.asArray() ?? []
    }

    /// Drop all retained samples. Primarily useful in tests.
    public func reset() {
        rings.removeAll(keepingCapacity: true)
        unavailableKinds.removeAll(keepingCapacity: true)
    }
}
