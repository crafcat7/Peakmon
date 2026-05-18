//
//  PeakmonCore.swift
//  PeakmonCore
//
//  Foundation module. Zero non-Apple dependencies.
//
//  Will host (v0.0 → v0.1):
//    • Metric protocol & concrete metric models
//    • MetricCollector protocol
//    • MetricsScheduler (actor)
//    • MetricsStore (@Observable)
//    • Logger facade
//    • AppEnvironment for DI
//
//  See Docs/ARCHITECTURE.md and memories/repo/code-conventions.md.
//

import Foundation
import OSLog

/// Shared `os.Logger` facade for the whole app.
///
/// Categories map to the major subsystems described in `ARCHITECTURE.md`.
public enum Log {
    public static let app = Logger(subsystem: "ai.peakmon", category: "app")
    public static let scheduler = Logger(subsystem: "ai.peakmon", category: "scheduler")
    public static let collectors = Logger(subsystem: "ai.peakmon", category: "collectors")
    public static let storage = Logger(subsystem: "ai.peakmon", category: "storage")
    public static let notifications = Logger(subsystem: "ai.peakmon", category: "notifications")
}

/// Marker namespace; concrete metric models, protocols, scheduler and store
/// will be added in v0.1.
public enum PeakmonCore {
    public static let versionMarker = "v0.0-scaffold"
}
