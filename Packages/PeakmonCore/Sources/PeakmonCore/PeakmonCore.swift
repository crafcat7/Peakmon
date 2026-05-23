//
//  PeakmonCore.swift
//  PeakmonCore
//
//  Foundation module. Zero non-Apple dependencies.
//
//  Hosts:
//    • Metric protocol & concrete metric models
//    • MetricCollector protocol
//    • MetricsScheduler (actor)
//    • MetricsStore (@Observable)
//    • SMC bridge
//    • IOReport bridge
//
//  See Docs/ARCHITECTURE.md and memories/repo/code-conventions.md.
//

import Foundation

/// Marker namespace; concrete metric models, protocols, scheduler and store
/// live in sibling files of this module.
public enum PeakmonCore {
    public static let versionMarker = "v0.1"
}
