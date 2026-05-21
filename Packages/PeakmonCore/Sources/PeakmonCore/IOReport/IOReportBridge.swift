//
//  IOReportBridge.swift
//  PeakmonCore
//
//  Thin wrapper around `/usr/lib/libIOReport.dylib`. The library is an
//  Apple SPI that powers `powermetrics(8)` and Activity Monitor's
//  "Energy" graphs; it exposes per-subsystem energy counters (CPU/GPU/
//  ANE/DRAM) that no public framework reports.
//
//  We bind to it dynamically via `dlopen` + `dlsym` instead of linking
//  so that:
//    • the app still builds and signs ad-hoc with no entitlement,
//    • a missing or relocated dylib in a future macOS only causes the
//      power feature to silently disable, not a launch-time crash, and
//    • we never put a private framework path in `LC_LOAD_DYLIB`.
//
//  Every `try Bridge()` call performs the resolve once; on any failure
//  the initializer throws and callers are expected to degrade silently
//  (the rest of Peakmon keeps running).
//

import Foundation

/// Strongly typed wrapper around the libIOReport channel-subscription
/// API. Opaque to callers — they only hand it back to `snapshot()` and
/// `Snapshot.delta(against:)`.
public final class IOReportBridge {
    /// Thrown when `dlopen` succeeds but a required symbol is missing,
    /// or when a subscription call returns nil for an otherwise valid
    /// group. Callers should swallow these and disable the feature.
    public enum BridgeError: Error, CustomStringConvertible {
        case dylibMissing(path: String)
        case symbolMissing(name: String)
        case groupEmpty(group: String)
        case subscribeFailed(group: String)
        case sampleFailed

        public var description: String {
            switch self {
            case .dylibMissing(let path): "libIOReport not found at \(path)"
            case .symbolMissing(let name): "libIOReport symbol missing: \(name)"
            case .groupEmpty(let g): "IOReport group has no channels: \(g)"
            case .subscribeFailed(let g): "IOReport subscribe failed for \(g)"
            case .sampleFailed: "IOReport sample call returned nil"
            }
        }
    }

    // C function pointers resolved once at init.
    private typealias FnCopyGroup = @convention(c) (CFString, CFString?) -> CFMutableDictionary?
    private typealias FnCreateSub = @convention(c) (
        UnsafeRawPointer?,
        CFMutableDictionary?,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
        UInt64,
        CFTypeRef?
    ) -> Unmanaged<AnyObject>?
    private typealias FnCreateSamples = @convention(c) (
        AnyObject?, CFMutableDictionary?, CFTypeRef?
    ) -> Unmanaged<CFDictionary>?
    private typealias FnDelta = @convention(c) (
        CFDictionary, CFDictionary, CFTypeRef?
    ) -> Unmanaged<CFDictionary>?
    private typealias FnChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias FnSimpleVal = @convention(c) (CFDictionary, Int32) -> Int64

    private let createSamples: FnCreateSamples
    private let createDelta: FnDelta
    private let getGroup: FnChannelString
    private let getName: FnChannelString
    private let getUnit: FnChannelString
    private let simpleVal: FnSimpleVal

    // Subscription state — retained for the lifetime of the bridge.
    private let subscription: AnyObject
    private let subscribedChannels: CFMutableDictionary
    private let groupName: String

    /// Resolve symbols, copy the channel list for `group`, and create a
    /// long-lived subscription. Throws `BridgeError` on any failure.
    public init(group: String) throws {
        let path = "/usr/lib/libIOReport.dylib"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            throw BridgeError.dylibMissing(path: path)
        }

        func resolve<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let raw = dlsym(handle, name) else {
                throw BridgeError.symbolMissing(name: name)
            }
            return unsafeBitCast(raw, to: type)
        }

        let copyGroup: FnCopyGroup = try resolve(
            "IOReportCopyChannelsInGroup", FnCopyGroup.self,
        )
        let createSub: FnCreateSub = try resolve(
            "IOReportCreateSubscription", FnCreateSub.self,
        )
        self.createSamples = try resolve(
            "IOReportCreateSamples", FnCreateSamples.self,
        )
        self.createDelta = try resolve(
            "IOReportCreateSamplesDelta", FnDelta.self,
        )
        self.getGroup = try resolve(
            "IOReportChannelGetGroup", FnChannelString.self,
        )
        self.getName = try resolve(
            "IOReportChannelGetChannelName", FnChannelString.self,
        )
        self.getUnit = try resolve(
            "IOReportChannelGetUnitLabel", FnChannelString.self,
        )
        self.simpleVal = try resolve(
            "IOReportSimpleGetIntegerValue", FnSimpleVal.self,
        )

        self.groupName = group
        guard let channels = copyGroup(group as CFString, nil) else {
            throw BridgeError.groupEmpty(group: group)
        }

        var out: Unmanaged<CFMutableDictionary>?
        guard let sub = createSub(nil, channels, &out, 0, nil) else {
            throw BridgeError.subscribeFailed(group: group)
        }
        self.subscription = sub.takeRetainedValue()
        // `out` is populated with the (possibly filtered) channel set
        // the kernel actually subscribed us to. We must reuse exactly
        // this dictionary in every subsequent `createSamples` call.
        guard let subscribed = out?.takeRetainedValue() else {
            throw BridgeError.subscribeFailed(group: group)
        }
        self.subscribedChannels = subscribed
    }

    /// Capture an instantaneous counter snapshot. Cheap (~1 ms) — call
    /// at the scheduler's normal cadence.
    public func snapshot() throws -> Snapshot {
        guard let raw = createSamples(subscription, subscribedChannels, nil) else {
            throw BridgeError.sampleFailed
        }
        return Snapshot(
            dictionary: raw.takeRetainedValue(),
            createDelta: createDelta,
            getGroup: getGroup,
            getName: getName,
            getUnit: getUnit,
            simpleVal: simpleVal,
        )
    }

    /// Reports the group name passed at init, for diagnostics.
    public var group: String { groupName }
}

extension IOReportBridge {
    /// Wraps the raw `IOReportChannels` dictionary returned by either a
    /// raw `IOReportCreateSamples` or a delta call. Use
    /// `delta(against:)` to convert two adjacent snapshots into a flat
    /// list of per-channel integer values.
    public struct Snapshot {
        fileprivate let dictionary: CFDictionary
        fileprivate let createDelta: (CFDictionary, CFDictionary, CFTypeRef?)
            -> Unmanaged<CFDictionary>?
        fileprivate let getGroup: (CFDictionary) -> Unmanaged<CFString>?
        fileprivate let getName: (CFDictionary) -> Unmanaged<CFString>?
        fileprivate let getUnit: (CFDictionary) -> Unmanaged<CFString>?
        fileprivate let simpleVal: (CFDictionary, Int32) -> Int64

        /// Compute per-channel deltas between `previous` and `self`.
        /// The order is `(previous, self)` so values are non-negative
        /// for monotonic counters. Returns an empty array on any
        /// internal failure (callers degrade gracefully).
        public func delta(against previous: Snapshot) -> [Reading] {
            guard let raw = createDelta(previous.dictionary, dictionary, nil) else {
                return []
            }
            let delta = raw.takeRetainedValue()
            return readings(in: delta)
        }

        /// Read absolute counter values out of the underlying dict.
        /// Mostly useful for one-shot enumeration / diagnostics; power
        /// reporting needs deltas.
        public var readings: [Reading] {
            readings(in: dictionary)
        }

        private func readings(in dict: CFDictionary) -> [Reading] {
            let key = "IOReportChannels" as CFString
            let ptr = CFDictionaryGetValue(
                dict, Unmanaged.passUnretained(key).toOpaque(),
            )
            guard let ptr else { return [] }
            let array = unsafeBitCast(ptr, to: CFArray.self)
            let count = CFArrayGetCount(array)
            var out: [Reading] = []
            out.reserveCapacity(count)
            for index in 0..<count {
                let itemPtr = CFArrayGetValueAtIndex(array, index)
                let item = unsafeBitCast(itemPtr, to: CFDictionary.self)
                let group = getGroup(item)?.takeUnretainedValue() as String? ?? ""
                let name = getName(item)?.takeUnretainedValue() as String? ?? ""
                let unit = getUnit(item)?.takeUnretainedValue() as String? ?? ""
                let value = simpleVal(item, 0)
                out.append(Reading(group: group, channel: name, unit: unit, value: value))
            }
            return out
        }
    }

    /// One channel's value extracted from a snapshot or delta. For the
    /// Energy Model group, `unit == "mJ"` and `value` is millijoules
    /// (delta) or cumulative millijoules since boot (raw snapshot).
    public struct Reading: Hashable, Sendable {
        public let group: String
        public let channel: String
        public let unit: String
        public let value: Int64
    }
}
