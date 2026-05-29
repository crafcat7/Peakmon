//
//  ProcessGrouping.swift
//  Peakmon
//
//  Folds a flat `[ProcessSnapshot]` list into `[ProcessGroup]`,
//  where each group corresponds to one user-visible application.
//
//  The grouping key is derived from the executable path:
//
//    1. If the path contains "/Foo.app/", the .app bundle root
//       becomes the key (e.g. "/Applications/Google Chrome.app").
//       This collapses Chrome's GPU / renderer / utility helpers,
//       Xcode's various XPC services, etc. into one row.
//    2. Otherwise the executable's leaf filename is used. This
//       keeps daemons like `mds`, `WindowServer`, or one-off CLI
//       processes as individual rows — there's no "app" to fold
//       them into.
//    3. Processes with no path at all (cross-user, kernel) fall
//       through to their reported process name as the key, so
//       they still appear as standalone rows.
//
//  The grouping pass runs entirely in pure-Swift on the View's
//  computed property; no caching is necessary at the ~500-PID
//  scale we observe (sub-millisecond on Apple silicon).
//

import AppKit
import Foundation
import PeakmonCore

/// Aggregated view of one user-visible application across all
/// its concurrently-running processes.
struct ProcessGroup: Identifiable, Equatable {
    /// Stable identity used both by SwiftUI's `ForEach` and by the
    /// detail sheet when the user double-clicks a row. The key is
    /// either an absolute .app-bundle path or a bare executable
    /// name, so collisions across ticks are vanishingly unlikely.
    let id: String

    /// Human-readable label shown in the table. For .app bundles
    /// this is the bundle's display name (`Info.plist` →
    /// `CFBundleName`, falling back to the bundle filename minus
    /// `.app`); otherwise it's the leaf executable name.
    let displayName: String

    /// Absolute path to the .app bundle root, if the group came
    /// from an app. Empty for daemons / kernel tasks. The detail
    /// sheet uses this to render the bundle icon at high res.
    let bundlePath: String

    /// Sum of `cpuPercent` across `children`. Same "100% per core"
    /// convention as the underlying snapshots.
    let totalCPU: Double

    /// Sum of resident bytes across `children`.
    let totalMemory: UInt64

    /// All snapshots backing this group, sorted descending by CPU%
    /// so the detail sheet can present "the heaviest child first"
    /// without re-sorting.
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

    /// Returns the canonical grouping key for one snapshot. The
    /// `.app` detection walks the path components rather than
    /// regex-matching so that paths containing accented or
    /// non-ASCII bundle names work without special-casing.
    private static func groupKey(for snap: ProcessSnapshot) -> String {
        let path = snap.path
        if path.isEmpty {
            // Fall back to the process name so daemons we can't
            // inspect still cluster sensibly (multiple workers of
            // the same daemon share a name).
            return "name:" + snap.name
        }
        if let bundle = appBundlePath(in: path) {
            return "bundle:" + bundle
        }
        // Standalone executable — group by absolute path so two
        // copies of the same binary in different locations stay
        // distinct, matching Activity Monitor.
        return "exec:" + path
    }

    /// Finds the deepest `.app` ancestor of the given path. Walks
    /// components from the end and stops at the first one that
    /// ends in `.app`, then reassembles the prefix. Returning
    /// `nil` means "this path is not inside an app bundle" and the
    /// caller should fall back to per-executable grouping.
    private static func appBundlePath(in path: String) -> String? {
        let comps = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let idx = comps.lastIndex(where: { $0.hasSuffix(".app") }) else {
            return nil
        }
        // Reassemble "/a/b/Foo.app".
        return "/" + comps[1 ... idx].joined(separator: "/")
    }

    // MARK: - Display info

    /// Returns `(displayName, bundlePath)` for a group. For bundle
    /// keys we ask `Bundle(path:)` for the display name, falling
    /// back to the filename minus extension if the bundle has no
    /// Info.plist (or we can't read it). For non-bundle keys the
    /// sample's `name` is already the right label.
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
        // For "name:" and "exec:" keys the snapshot's own process
        // name is the most accurate label (proc_name has already
        // trimmed it to the BSD command form).
        return (sample.name, "")
    }

    /// Read `CFBundleDisplayName` / `CFBundleName` from the bundle
    /// at `path`. Marked private so we don't accidentally rely on
    /// it as a general bundle utility — the only consumer is the
    /// grouping pass above. Returns `nil` if the bundle is
    /// unreadable, which the caller treats as "use the filename".
    ///
    /// **Cached.** `Bundle(path:)` is not cheap — it triggers a
    /// full `_CFBundleCreate` traversal of the bundle's resources
    /// directory and a `_CSCheckFixBugForBundleAndVersion` call
    /// against CoreServices. Sampling showed those routines were
    /// the single largest contributor to dashboard main-thread
    /// time, costing tens of percent CPU at a 1s tick. Since
    /// bundle display names are immutable for the life of the
    /// process, we memoize them in a serial-queue-guarded
    /// dictionary keyed by absolute bundle path.
    private static let bundleNameCache = BundleNameCache()

    private static func bundleDisplayName(at path: String) -> String? {
        bundleNameCache.name(forBundleAt: path)
    }
}

/// Thread-safe lazy cache from bundle path → display name.
/// Implemented as a class with a dispatch lock so the grouping
/// pass — which may run from a background `Task` once we move
/// it off the main thread — never sees a torn dictionary.
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
        // doesn't block other groups from reading their already-
        // resolved entries.
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
