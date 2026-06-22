//
//  MetricRingBuffer.swift
//  PeakmonCore
//
//  Fixed-capacity, oldest-first ring buffer of `MetricSample`s used
//  by `MetricsStore` to retain a rolling window per `MetricKind`.
//
//  ## Why this exists
//
//  v1.0–v1.2 stored each kind's history as a plain `Array` and used
//  `removeFirst()` to evict the oldest sample on every overflow. That
//  is **O(n) per ingest** because `Array.removeFirst()` shifts every
//  remaining element down by one (`memmove`). At the 1 Hz, 120-sample
//  window the dashboard ran with originally that was fine — 120
//  bytes shifted once per second per kind is unmeasurable.
//
//  v1.3's dashboard surfaces a 1-hour timeline, which means
//  `historyLimit` jumps to 3600. Eleven collectors emitting at 1 Hz
//  would then memmove 11 × 3600 ≈ 40 k samples per second forever,
//  bumping per-tick CPU cost from "free" to "measurable on Activity
//  Monitor". A fixed ring buffer makes append + evict **O(1)**
//  regardless of capacity.
//
//  ## Design
//
//  - Storage is a `ContiguousArray<MetricSample?>` of `capacity`
//    slots, allocated once at init. `Optional` because slot reuse
//    requires a writable cell before any sample exists in it; the
//    `nil` overhead is one extra byte per `MetricSample` (which is
//    already 40+ bytes) and avoids unsafe-pointer initialisation
//    dances.
//  - `head` indexes the oldest live element; `count` tracks how many
//    slots are populated. `append` writes to `(head + count) %
//    capacity` when not yet full, otherwise overwrites `head` and
//    advances `head` by one.
//  - `asArray()` materialises the live window as a fresh
//    `[MetricSample]` in oldest-first order. SwiftUI Charts and the
//    menu-bar rasteriser both already iterate the whole window per
//    body pass, so paying O(n) on snapshot is a wash; what matters
//    is that ingest stays O(1).
//
//  Not `Sendable` because `MetricsStore` already constrains use to
//  the main actor — the buffer is a value-semantics implementation
//  detail of an `@MainActor` type.
//

import Foundation

/// Fixed-capacity ring buffer of `MetricSample`s, oldest-first when
/// materialised via `asArray()`. Append + overflow eviction are both
/// O(1); snapshot is O(n).
struct MetricRingBuffer {
    /// Maximum number of live samples retained. Set once at init and
    /// invariant for the buffer's lifetime — callers that need to
    /// resize should construct a new buffer and copy through
    /// `asArray()` rather than mutating in place, because resizing
    /// a ring buffer without losing samples is more code than it's
    /// worth for a path that never runs in practice.
    let capacity: Int

    /// Backing storage. `nil` in slots that have not yet been
    /// written; once a slot has been populated it is never reset to
    /// `nil` (subsequent appends overwrite in place).
    private var storage: ContiguousArray<MetricSample?>

    /// Index of the oldest live element, or 0 when `count == 0`.
    /// Always in `0..<capacity`.
    private var head: Int = 0

    /// Number of live elements, in `0...capacity`.
    private(set) var count: Int = 0

    /// Allocates `capacity` slots up front so subsequent appends
    /// never trigger a heap growth and `removeFirst()`-style
    /// memmoves become impossible by construction.
    init(capacity: Int) {
        precondition(capacity > 0, "MetricRingBuffer capacity must be positive")
        self.capacity = capacity
        self.storage = ContiguousArray(repeating: nil, count: capacity)
    }

    /// Appends `sample`. If the buffer is already at capacity the
    /// oldest sample is overwritten and `head` advances, both in
    /// O(1) — no memmove, no allocation.
    mutating func append(_ sample: MetricSample) {
        if count < capacity {
            let writeIndex = (head + count) % capacity
            storage[writeIndex] = sample
            count += 1
        } else {
            // Buffer full: overwrite the oldest slot (which is at
            // `head`) and rotate `head` forward so the new sample
            // becomes the newest, not the oldest.
            storage[head] = sample
            head = (head + 1) % capacity
        }
    }

    /// Most recent sample, or `nil` if the buffer is empty.
    /// Equivalent to `asArray().last` but skips the full snapshot.
    var last: MetricSample? {
        guard count > 0 else { return nil }
        let tail = (head + count - 1) % capacity
        return storage[tail]
    }

    /// Materialises the live window as a fresh `[MetricSample]` in
    /// oldest-first order. Allocates `count` slots. Returning an
    /// empty array for an empty buffer keeps SwiftUI's diff path
    /// identical to the previous `Array`-backed implementation.
    func asArray() -> [MetricSample] {
        guard count > 0 else { return [] }
        var out: [MetricSample] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let idx = (head + i) % capacity
            // Force-unwrap is safe: any index in `0..<count` is
            // guaranteed to have been written at least once because
            // we only ever increment `count` immediately after
            // writing a slot.
            out.append(storage[idx]!)
        }
        return out
    }

    /// Materialises at most the latest `limit` samples in
    /// oldest-first order. This avoids copying the full history when
    /// callers only need a fixed-size window (for example, the
    /// 18-sample menu-bar charts).
    func suffix(_ limit: Int) -> [MetricSample] {
        guard count > 0 && limit > 0 else { return [] }
        let safeLimit = min(limit, count)
        var out: [MetricSample] = []
        out.reserveCapacity(safeLimit)
        let start = (head + count - safeLimit) % capacity
        for i in 0..<safeLimit {
            let idx = (start + i) % capacity
            out.append(storage[idx]!)
        }
        return out
    }

    /// Drops every live sample without releasing the backing
    /// storage. Used by `MetricsStore.reset()` in tests.
    mutating func removeAll() {
        head = 0
        count = 0
        // Intentionally do not nil out the slots: they are private
        // and the only readers (`asArray`, `last`) gate on `count`.
    }
}
