//
//  DeviceInfoReader.swift
//  Peakmon
//
//  One-shot system identity gatherer for the dashboard's
//  device banner. Every field is sourced from a public,
//  entitlement-free API:
//
//    • `hw.model`                     -> internal model id (e.g. "Mac15,9")
//    • IOPlatformExpertDevice
//        - `product-name`             -> marketing name fallback
//        - `IOPlatformSerialNumber`   -> serial number (masked in UI)
//    • `machdep.cpu.brand_string`     -> chip brand line
//    • `hw.perflevel0.physicalcpu`    -> P-core count (used for "Apple M3 8C")
//    • `hw.perflevel1.physicalcpu`    -> E-core count
//    • `hw.memsize`                   -> total physical RAM
//    • `FileManager.attributesOfFileSystem(forPath: "/")`
//                                     -> startup volume total capacity
//    • `ProcessInfo.operatingSystemVersion` + marketing-name table
//    • `kern.boottime`                -> system boot Date (used for uptime)
//
//  Everything except `bootDate` is constant for the life of
//  the process, so we read once at init and cache. `bootDate`
//  is also constant per boot but the *uptime derived from it*
//  changes every second, which is why the view recomputes
//  uptime on its own timer rather than caching it here.
//

import Darwin
import Foundation
import IOKit

struct DeviceInfo: Sendable {
    /// Marketing name from IORegistry — e.g. "MacBook Pro".
    /// Falls back to the raw model id if the registry entry
    /// is missing on a particular machine.
    let modelName: String

    /// `hw.model` raw string (e.g. "Mac15,9"). Always shown as
    /// the secondary identifier so a user with two identical
    /// chassis can still tell them apart.
    let modelIdentifier: String

    /// Marketed chip name with core count, e.g.
    /// "Apple M3 Pro (12-core CPU)". Built from
    /// `machdep.cpu.brand_string` + perflevel counts so we
    /// don't depend on a hand-curated SoC table.
    let chip: String

    /// Total installed RAM in bytes.
    let memoryBytes: UInt64

    /// Total bytes of the startup volume (`/`). Used over the
    /// "free" number because the banner is about identity,
    /// not capacity-planning — the Disk card already shows
    /// free space.
    let diskBytes: UInt64

    /// e.g. "macOS Sequoia 15.4". Marketing name is best-effort;
    /// when unknown we fall back to "macOS X.Y".
    let osVersion: String

    /// System boot time. The banner subtracts `now` from this
    /// every minute to render uptime.
    let bootDate: Date

    /// Hardware serial number. May be empty if the IORegistry
    /// is locked down (rare). The view applies its own mask
    /// before displaying.
    let serialNumber: String
}

enum DeviceInfoReader {
    /// Gather the full set in one call. Cheap enough (a few
    /// sysctls + one IORegistry lookup) to run synchronously
    /// on the main actor at view init, but we still expose it
    /// as `nonisolated` so callers may also push it onto a
    /// background task if they prefer.
    nonisolated static func read() -> DeviceInfo {
        let modelId = sysctlString("hw.model") ?? "Mac"
        let chipBrand = sysctlString("machdep.cpu.brand_string") ?? "Apple silicon"
        let pCores = sysctlInt("hw.perflevel0.physicalcpu") ?? 0
        let eCores = sysctlInt("hw.perflevel1.physicalcpu") ?? 0
        let totalCores = max(pCores + eCores, sysctlInt("hw.physicalcpu") ?? 0)

        let chip: String = {
            if totalCores > 0 {
                return "\(chipBrand) · \(totalCores)-core CPU (\(pCores)P + \(eCores)E)"
            }
            return chipBrand
        }()

        let memsize: UInt64 = sysctlUInt64("hw.memsize") ?? 0
        let bootDate = sysctlBootTime() ?? Date(timeIntervalSince1970: 0)

        let (productName, serial) = ioPlatformExpertInfo()
        let modelName = productName ?? friendlyName(forModelId: modelId)

        let disk: UInt64 = {
            // `attributesOfFileSystem(forPath:)` returns the same
            // raw block-device size that `df` reports — the
            // sticker-capacity number the user expects to see.
            let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/")
            return (attrs?[.systemSize] as? NSNumber)?.uint64Value ?? 0
        }()

        return DeviceInfo(
            modelName: modelName,
            modelIdentifier: modelId,
            chip: chip,
            memoryBytes: memsize,
            diskBytes: disk,
            osVersion: osMarketingName(),
            bootDate: bootDate,
            serialNumber: serial,
        )
    }

    // MARK: - sysctl helpers

    /// String-valued sysctl. Sized via a two-call probe so we
    /// don't have to hard-code a max length per key.
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    /// `kern.boottime` returns a `timeval` whose tv_sec field
    /// is the wall-clock boot moment.
    private static func sysctlBootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        let result = "kern.boottime".withCString { name in
            sysctlbyname(name, &tv, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }

    // MARK: - IORegistry

    /// Pulls `product-name` and `IOPlatformSerialNumber` out
    /// of the `IOPlatformExpertDevice` root entry in one open.
    /// Returns (`nil`, "") if the registry lookup fails for
    /// any reason — both call sites tolerate missing values.
    private static func ioPlatformExpertInfo() -> (productName: String?, serial: String) {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice"),
        )
        guard service != 0 else { return (nil, "") }
        defer { IOObjectRelease(service) }

        // `product-name` is a CFData containing a NUL-terminated
        // ASCII byte string — typed weakly in IOKit headers.
        let productName: String? = {
            guard let raw = IORegistryEntryCreateCFProperty(
                service,
                "product-name" as CFString,
                kCFAllocatorDefault,
                0,
            )?.takeRetainedValue() as? Data else { return nil }
            return String(data: raw, encoding: .utf8)?
                .trimmingCharacters(in: .controlCharacters)
        }()

        let serial: String = {
            guard let raw = IORegistryEntryCreateCFProperty(
                service,
                kIOPlatformSerialNumberKey as CFString,
                kCFAllocatorDefault,
                0,
            )?.takeRetainedValue() as? String else { return "" }
            return raw
        }()

        return (productName, serial)
    }

    // MARK: - Friendly fallbacks

    /// Coarse hand fallback when IORegistry doesn't expose a
    /// product-name (older Macs, rare). We only need to bucket
    /// to one of the four current product lines; the exact
    /// generation comes from the chip line below it.
    private static func friendlyName(forModelId id: String) -> String {
        if id.hasPrefix("MacBookPro") { return "MacBook Pro" }
        if id.hasPrefix("MacBookAir") { return "MacBook Air" }
        if id.hasPrefix("Macmini")    { return "Mac mini" }
        if id.hasPrefix("MacStudio")  { return "Mac Studio" }
        if id.hasPrefix("MacPro")     { return "Mac Pro" }
        if id.hasPrefix("iMac")       { return "iMac" }
        return "Mac"
    }

    /// macOS marketing name + version, e.g.
    /// "macOS Sequoia 15.4 (24E5083)". We keep the build
    /// number off the banner because it makes the chip too
    /// long; users who care can read it in About This Mac.
    private static func osMarketingName() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let marketing: String
        switch v.majorVersion {
        case 26: marketing = "macOS Tahoe"      // anticipating Apple's announced name
        case 15: marketing = "macOS Sequoia"
        case 14: marketing = "macOS Sonoma"
        case 13: marketing = "macOS Ventura"
        case 12: marketing = "macOS Monterey"
        case 11: marketing = "macOS Big Sur"
        default: marketing = "macOS"
        }
        return "\(marketing) \(v.majorVersion).\(v.minorVersion)\(v.patchVersion > 0 ? ".\(v.patchVersion)" : "")"
    }
}
