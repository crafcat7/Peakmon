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
            accessory: {
                Text(sortLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            },
            body: {
                // Rows are sized so 5 caption-height entries (≈13pt
                // each) plus their inter-row spacing fill the
                // template's pinned 94pt content area: 5 × 13 + 4 ×
                // 7 = 93pt. Without the wider spacing the rows
                // huddle at the top of the card and the freeform
                // body leaves a visually distracting empty band
                // along the bottom.
                VStack(alignment: .leading, spacing: 7) {
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
