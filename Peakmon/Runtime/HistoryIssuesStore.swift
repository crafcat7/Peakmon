//
//  HistoryIssuesStore.swift
//  Peakmon
//

import Foundation
import Observation
import PeakmonCore
import UserNotifications

@MainActor
@Observable
final class HistoryIssuesStore {
    private(set) var recentEvents: [HistoryAnomalyEvent] = []
    private var seenEventIDs: Set<UUID> = []
    private(set) var focusedEventID: UUID?
    private(set) var focusedMetric: HistoryMetricDefinition?
    private(set) var navigationRevision = 0

    var highestSeverity: HistoryAnomalySeverity? {
        recentEvents.map(\.severity).max()
    }

    var menuBarSignatureValues: [Double] {
        [
            Double(recentEvents.count),
            Double(highestSeverity?.rawValue ?? 0),
        ]
    }

    func requestHistoryFocus(for event: HistoryAnomalyEvent?) {
        focusedEventID = event?.id
        focusedMetric = event.map { Self.metricDefinition(for: $0.kind) }
        navigationRevision &+= 1
    }

    func update(_ events: [HistoryAnomalyEvent], at now: Date = .now) {
        let cutoff = now.addingTimeInterval(-HistoryRange.oneHour.duration)
        let recent = events
            .filter { $0.endDate >= cutoff && $0.startDate <= now }
            .sorted { $0.startDate > $1.startDate }
        let newEvents = recent.filter { !seenEventIDs.contains($0.id) }

        recentEvents = recent
        seenEventIDs.formUnion(recent.map(\.id))

        guard !newEvents.isEmpty else { return }
        Task(priority: .utility) {
            await HistoryIssueNotificationService.deliver(newEvents)
        }
    }

    private static func metricDefinition(for kind: HistoryAnomalyKind) -> HistoryMetricDefinition {
        switch kind {
        case .cpuSustainedHigh:
            .cpu
        case .memoryPressure, .memorySwapHigh:
            .memory
        case .powerSustainedHigh:
            .power
        case .gpuSustainedHigh:
            .gpu
        case .diskReadSustainedHigh, .diskWriteSustainedHigh:
            .disk
        case .networkInSustainedHigh, .networkOutSustainedHigh:
            .network
        case .thermalCPUHigh, .thermalGPUHigh:
            .temperature
        }
    }
}

enum HistoryIssueNotificationService {
    nonisolated static let enabledKey = "historyAnomalyNotificationsEnabled"

    nonisolated static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound],
            )
        } catch {
            return false
        }
    }

    nonisolated static func deliver(_ events: [HistoryAnomalyEvent]) async {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        else { return }

        for event in events {
            let content = UNMutableNotificationContent()
            content.title = "Peakmon detected \(title(for: event.kind))"
            content.body = body(for: event)
            content.categoryIdentifier = "PEAKMON_HISTORY_ANOMALY"
            if event.severity == .high {
                content.sound = .default
            }

            let request = UNNotificationRequest(
                identifier: "history-anomaly-\(event.id.uuidString)",
                content: content,
                trigger: nil,
            )
            try? await center.add(request)
        }
    }

    nonisolated private static func body(for event: HistoryAnomalyEvent) -> String {
        guard let process = event.processes.first else { return event.reason }
        switch event.kind {
        case .memoryPressure, .memorySwapHigh:
            let memory = ByteCountFormatter.string(fromByteCount: Int64(process.memoryBytes), countStyle: .memory)
            return "Likely contributor: \(process.name) using \(memory)."
        case .cpuSustainedHigh, .powerSustainedHigh:
            return "Likely contributor: \(process.name) at \(Int(process.cpuPercent.rounded()))% CPU."
        default:
            return event.reason
        }
    }

    nonisolated private static func title(for kind: HistoryAnomalyKind) -> String {
        switch kind {
        case .cpuSustainedHigh: "sustained CPU usage"
        case .gpuSustainedHigh: "sustained GPU usage"
        case .memoryPressure: "memory pressure"
        case .memorySwapHigh: "elevated swap"
        case .powerSustainedHigh: "sustained power draw"
        case .diskReadSustainedHigh: "sustained disk reads"
        case .diskWriteSustainedHigh: "sustained disk writes"
        case .networkInSustainedHigh: "sustained network receive"
        case .networkOutSustainedHigh: "sustained network send"
        case .thermalCPUHigh: "high CPU temperature"
        case .thermalGPUHigh: "high GPU temperature"
        }
    }
}
