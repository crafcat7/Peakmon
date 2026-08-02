//
//  ProcessesCard.swift
//  Peakmon
//
//  Dashboard top-processes card: reads `processesStore`, which
//  the ProcessCollector refreshes every 2 s on a background task,
//  and renders the top 5 sorted by CPU (default) or RAM. Sort
//  order is controlled by the `processesSortByMemory` AppStorage
//  flag set elsewhere in the UI.
//

import PeakmonCore
import PeakmonUI
import SwiftUI

struct ProcessesCard: View {
    @Environment(ProcessesStore.self) private var processesStore
    @Environment(\.cardSettings) private var cardSettings

    @AppStorage("processesSortByMemory") private var sortByMemory = false

    private var tint: Color { cardSettings.tint(.processes) }

    var body: some View {
        let processes = processesStore.latestProcesses
        let sorted: [ProcessSnapshot] = if sortByMemory {
            processes.sorted { $0.memoryBytes > $1.memoryBytes }
        } else {
            processes // collector already pre-sorts by CPU desc
        }
        let top = Array(sorted.prefix(5))
        let sortLabel = sortByMemory ? "by RAM" : "by CPU"

        return DashboardCardTemplate(
            title: "Top Processes",
            systemImage: "list.bullet.rectangle",
            tint: tint,
            minimumHeight: 128,
            contentHeight: 74,
            accessory: {
                Text(LocalizedStringKey(sortLabel))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            },
            body: {
                VStack(alignment: .leading, spacing: 1) {
                    if top.isEmpty {
                        Text("Collecting…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(top) { snapshot in
                            ProcessRow(
                                snapshot: snapshot,
                                showMemory: sortByMemory,
                            )
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            },
        )
    }
}
