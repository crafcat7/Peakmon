//
//  MenuBarDisplayMode.swift
//  Peakmon
//
//  Menu bar appearance model. A user can compose the label out of any
//  combination of `MenuBarSegment` values. The chosen segments are
//  persisted as a comma-separated raw-value list via `@AppStorage` so
//  the order is preserved across launches.
//

import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// One atomic piece of menu bar content. The label is built by
/// concatenating the user's selected segments with `|` separators.
enum MenuBarSegment: String, CaseIterable, Identifiable, Codable, Equatable, Transferable {
    case cpuPercent
    case cpuGraph
    case memoryPercent
    case memoryGraph
    case networkRate
    case networkGraph
    case diskRate
    case diskGraph
    case batteryPercent
    case gpuPercent
    case gpuGraph
    case powerWatts
    case powerGraph

    var id: String { rawValue }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .plainText)
    }

    var title: String { descriptor.title }

    var systemImage: String { descriptor.systemImage }
}

/// Persists and reads the ordered set of selected segments. Stored as
/// a comma-joined raw-value string so it round-trips through
/// `@AppStorage(String)` without bringing along a custom codable
/// layer.
enum MenuBarComposition {
    static let storageKey = "menuBarSegments"

    /// Default selection used on first launch and when the saved
    /// string fails to decode.
    static let defaultSegments: [MenuBarSegment] = [.cpuPercent]

    static func encode(_ segments: [MenuBarSegment]) -> String {
        segments.map(\.rawValue).joined(separator: ",")
    }

    static func decode(_ raw: String) -> [MenuBarSegment] {
        let pieces = raw.split(separator: ",").map(String.init)
        let parsed = pieces.compactMap(MenuBarSegment.init(rawValue:))
        return parsed.isEmpty ? defaultSegments : parsed
    }
}
