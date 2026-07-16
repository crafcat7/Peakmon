//
//  ProcessGrouping.swift
//  Peakmon
//
//  Folds a flat `[ProcessSnapshot]` list into `[ProcessGroup]`, one
//  group per user-visible application. Grouping key, by executable
//  path:
//
//    1. Path contains "/Foo.app/" → the .app bundle root is the key
//       (collapses Chrome's helpers, Xcode's XPC services, etc.).
//    2. Otherwise the absolute executable path (daemons / CLI tools
//       stay as their own rows).
//    3. No path (cross-user / kernel) → the process name.
//
//  Pure Swift, no caching needed at the ~500-PID scale
//  (sub-millisecond on Apple silicon).
//

import AppKit
import Foundation
import PeakmonCore

/// Aggregated view of one user-visible application across all
/// its concurrently-running processes.
struct ProcessGroup: Identifiable, Equatable {
    /// Stable identity for `ForEach` and the detail sheet — an
    /// absolute .app-bundle path or a bare executable name.
    let id: String

    /// Label shown in the table: a bundle's display name
    /// (`CFBundleName`, else filename minus `.app`) or the leaf
    /// executable name.
    let displayName: String

    /// Absolute .app bundle root, or empty for daemons / kernel
    /// tasks. The detail sheet uses it for the bundle icon.
    let bundlePath: String

    /// Sum of `cpuPercent` across `children` (100%-per-core).
    let totalCPU: Double

    /// Sum of resident bytes across `children`.
    let totalMemory: UInt64

    /// Snapshots backing this group, sorted descending by CPU% so
    /// the detail sheet shows the heaviest child first.
    let children: [ProcessSnapshot]
}

enum ProcessGrouping {
    /// Folds the input list into one group per resolved application
    /// key. `sortedBy` controls which metric orders the returned
    /// groups; `ascending` flips the direction. The table header
    /// toggles both — clicking a new column selects it (descending
    /// by default), clicking the active column flips direction.
    static func group(
        _ snapshots: [ProcessSnapshot],
        sortedBy: GroupSortKey,
        ascending: Bool = false,
    ) -> [ProcessGroup] {
        var buckets: [String: [ProcessSnapshot]] = [:]
        buckets.reserveCapacity(snapshots.count / 4 + 8)

        for snap in snapshots {
            let key = groupKey(for: snap)
            buckets[key, default: []].append(snap)
        }

        var groups: [ProcessGroup] = []
        groups.reserveCapacity(buckets.count)

        for (key, snaps) in buckets {
            let totalCPU = snaps.reduce(0.0) { $0 + $1.cpuPercent }
            let totalMem = snaps.reduce(UInt64(0)) { $0 + $1.memoryBytes }
            let sortedChildren = snaps.sorted { $0.cpuPercent > $1.cpuPercent }
            let (displayName, bundlePath) = displayInfo(forKey: key, sample: snaps[0])
            groups.append(ProcessGroup(
                id: key,
                displayName: displayName,
                bundlePath: bundlePath,
                totalCPU: totalCPU,
                totalMemory: totalMem,
                children: sortedChildren,
            ))
        }

        switch sortedBy {
        case .cpu:
            groups.sort { ascending ? $0.totalCPU < $1.totalCPU : $0.totalCPU > $1.totalCPU }
        case .memory:
            groups.sort { ascending ? $0.totalMemory < $1.totalMemory : $0.totalMemory > $1.totalMemory }
        }
        return groups
    }

    enum GroupSortKey {
        case cpu
        case memory
    }

    // MARK: - Key derivation

    /// Returns the canonical grouping key for one snapshot. `.app`
    /// detection walks path components (not regex) so non-ASCII
    /// bundle names need no special-casing.
    private static func groupKey(for snap: ProcessSnapshot) -> String {
        let path = snap.path
        if path.isEmpty {
            // No path: cluster by process name so daemon workers
            // sharing a name group together.
            return "name:" + snap.name
        }
        if let bundle = appBundlePath(in: path) {
            return "bundle:" + bundle
        }
        // Standalone executable: group by absolute path so two
        // copies in different locations stay distinct (matches
        // Activity Monitor).
        return "exec:" + path
    }

    /// Deepest `.app` ancestor of `path`, or `nil` if not inside a
    /// bundle (caller falls back to per-executable grouping).
    private static func appBundlePath(in path: String) -> String? {
        let comps = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let idx = comps.lastIndex(where: { $0.hasSuffix(".app") }) else {
            return nil
        }
        return "/" + comps[1 ... idx].joined(separator: "/")
    }

    // MARK: - Display info

    /// `(displayName, bundlePath)` for a group. Bundle keys resolve
    /// via `Bundle(path:)`, falling back to the filename minus
    /// extension; non-bundle keys use the snapshot's `name`.
    private static func displayInfo(forKey key: String, sample: ProcessSnapshot)
        -> (displayName: String, bundlePath: String)
    {
        if key.hasPrefix("bundle:") {
            let bundlePath = String(key.dropFirst("bundle:".count))
            let name = bundleDisplayName(at: bundlePath)
                ?? (bundlePath as NSString).lastPathComponent
                    .replacingOccurrences(of: ".app", with: "")
            return (name, bundlePath)
        }
        return (sample.name, "")
    }

    /// `CFBundleDisplayName` / `CFBundleName` for the bundle at
    /// `path`, or `nil` if unreadable (caller uses the filename).
    ///
    /// Cached: `Bundle(path:)` triggers a full `_CFBundleCreate`
    /// resource-dir traversal plus a CoreServices check, which
    /// sampling showed was the single largest dashboard main-thread
    /// cost (tens of percent CPU at a 1 s tick). Display names are
    /// immutable for the process lifetime, so we memoize by path.
    private static let bundleNameCache = BundleNameCache()

    private static func bundleDisplayName(at path: String) -> String? {
        bundleNameCache.name(forBundleAt: path)
    }
}

/// Thread-safe lazy cache from bundle path → display name. A
/// lock-guarded class so the grouping pass never sees a torn
/// dictionary if it moves off the main thread.
private final class BundleNameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String?] = [:]

    func name(forBundleAt path: String) -> String? {
        lock.lock()
        if let cached = storage[path] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Compute outside the lock so a slow `Bundle(path:)` call
        // doesn't block other groups from reading resolved entries.
        let resolved: String? = {
            guard let bundle = Bundle(path: path) else { return nil }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
               !name.isEmpty
            {
                return name
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
               !name.isEmpty
            {
                return name
            }
            return nil
        }()

        lock.lock()
        storage[path] = resolved
        lock.unlock()
        return resolved
    }
}
