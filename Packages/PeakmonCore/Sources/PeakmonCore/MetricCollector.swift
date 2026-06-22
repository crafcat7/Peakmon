//
//  MetricCollector.swift
//  PeakmonCore
//
//  Protocol every concrete metric collector implements. The scheduler
//  drives collectors at a configurable cadence; collectors stay
//  stateless or own their own state (e.g. previous CPU ticks) but never
//  reach into the rest of the app.
//

import Foundation

/// Produces one or more `MetricSample`s when polled.
///
/// Collectors are run on a background `Task` by `MetricsScheduler`. They
/// must be safe to call concurrently from outside MainActor (hence the
/// `Sendable` requirement) but may keep internal state synchronized via
/// an actor or lock if needed.
public protocol MetricCollector: Sendable {
    /// Stable identifier for diagnostics / logging.
    var identifier: String { get }

    /// Sample the underlying source and return zero or more samples.
    ///
    /// Collectors that fail transiently should throw; the scheduler logs
    /// the error and continues polling on the next tick.
    func collect() async throws -> [MetricSample]
}

/// Optional capability for collectors whose samples are derived from
/// deltas against a previous snapshot. Demand-gated runtimes call this
/// before reactivating such collectors so the first visible tick seeds
/// a fresh baseline instead of averaging across the hidden interval.
public protocol ResettableMetricCollector: MetricCollector {
    func reset() async
}
