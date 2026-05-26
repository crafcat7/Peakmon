//
//  SMCBridge.swift
//  PeakmonCore
//
//  Thin Swift wrapper around Apple's `AppleSMC` IOService. SMC exposes
//  per-rail power/temperature/voltage/fan sensors via four-character-
//  code keys; we use it to read the **whole-system** power draw that
//  IOReport's "Energy Model" group does NOT cover (display panel,
//  Wi-Fi, Thunderbolt PHYs, SSD, fan, AC adapter losses, ...).
//
//  AppleSMC is a private IOService but the user-mode protocol (selector
//  numbers, struct layout, command codes) has been stable since
//  ~10.6.7 and is used by every reputable open-source monitoring tool
//  (stats, iStats, SMCKit, TG Pro, Mx Power Gadget). We rely on it the
//  same way we rely on libIOReport: no entitlement, ad-hoc signing
//  works, and any future breakage causes the feature to silently
//  disable rather than crash the app.
//
//  ## Key codes worth knowing (Apple Silicon)
//
//  | Key  | 4-CC | Meaning                          | Unit |
//  |------|------|----------------------------------|------|
//  | PSTR | 0x50535452 | System total power           | W    |
//  | PDTR | 0x50445452 | Adapter (DC-in) delivery power| W    |
//  | BATP | 0x42415450 | Battery in/out power          | W    |
//  | PHPC | 0x50485043 | CPU heat-pipe power           | W    |
//  | PHPG | 0x50485047 | GPU heat-pipe power           | W    |
//
//  Not every key exists on every machine. Callers MUST probe with
//  `info(key:)` first and degrade if the key is missing.
//

import Foundation
import IOKit

/// Errors thrown by `SMCBridge`. Treat all of them as "feature is
/// unavailable" — callers should disable the feature rather than
/// surface the error to the user.
public enum SMCError: Error, CustomStringConvertible {
    case openFailed(kern_return_t)
    case callFailed(kern_return_t, command: UInt8)
    case keyNotFound(SMCKey)
    case unsupportedType(SMCKey, type: String)

    public var description: String {
        switch self {
        case .openFailed(let kr): "SMC open failed: 0x\(String(kr, radix: 16))"
        case .callFailed(let kr, let cmd):
            "SMC call \(cmd) failed: 0x\(String(kr, radix: 16))"
        case .keyNotFound(let key): "SMC key not found: \(key.fourCC)"
        case .unsupportedType(let key, let type):
            "SMC key \(key.fourCC) has unsupported type: \(type)"
        }
    }
}

/// Strongly typed four-character SMC key.
public struct SMCKey: Hashable, Sendable, CustomStringConvertible {
    public let raw: UInt32

    /// Constructs from a four-character ASCII string. Crashes on
    /// programmer error (length != 4 or non-ASCII) — these are all
    /// compile-time constants in our code.
    public init(_ fourCC: String) {
        precondition(fourCC.utf8.count == 4, "SMCKey must be 4 ASCII chars: \(fourCC)")
        var value: UInt32 = 0
        for byte in fourCC.utf8 {
            value = (value << 8) | UInt32(byte)
        }
        self.raw = value
    }

    public var fourCC: String {
        let bytes: [UInt8] = [
            UInt8((raw >> 24) & 0xFF),
            UInt8((raw >> 16) & 0xFF),
            UInt8((raw >> 8) & 0xFF),
            UInt8(raw & 0xFF),
        ]
        return String(decoding: bytes, as: UTF8.self)
    }

    public var description: String { fourCC }

    // MARK: - Well-known power keys (W)

    /// System total power. Headline "what does the whole machine
    /// draw" on every Apple Silicon Mac we've tested.
    public static let systemTotal = SMCKey("PSTR")
    /// Adapter (DC-in) delivery power; non-zero when plugged in.
    public static let adapter = SMCKey("PDTR")
    /// Battery in/out power. Sign convention varies by model;
    /// callers should treat |value| as magnitude.
    public static let battery = SMCKey("BATP")
    /// CPU heat-pipe power (Apple Silicon proxy for whole-CPU rail).
    public static let cpuHeatpipe = SMCKey("PHPC")
    /// GPU heat-pipe power.
    public static let gpuHeatpipe = SMCKey("PHPG")

    // MARK: - Thermal sensors (°C)
    //
    // Apple Silicon exposes `Tp**` (P-core dies), `Tg**` (GPU dies),
    // and `T*0P` proximity sensors. The exact set varies by SoC;
    // ThermalCollector probes a whitelist and aggregates the hottest
    // reading per category.

    public static let cpuDieP1 = SMCKey("Tp01")
    public static let cpuDieP2 = SMCKey("Tp05")
    public static let cpuDieP3 = SMCKey("Tp09")
    public static let cpuDieP4 = SMCKey("Tp0D")
    /// CPU proximity sensor; last-resort fallback.
    public static let cpuProximity = SMCKey("TC0P")

    public static let gpuDie1 = SMCKey("Tg05")
    public static let gpuDie2 = SMCKey("Tg0D")
    /// GPU proximity sensor; fallback when die keys absent.
    public static let gpuProximity = SMCKey("TG0P")

    // MARK: - Fan (RPM)
    //
    // `F<n><Ac|Mn|Mx|Tg>` pattern. Fanless designs (MacBook Air,
    // base Mac mini) have no `F0*` keys; FanCollector emits nothing
    // on those hosts.

    public static let fan0Actual = SMCKey("F0Ac")
    public static let fan0Min = SMCKey("F0Mn")
    public static let fan0Max = SMCKey("F0Mx")
    public static let fan1Actual = SMCKey("F1Ac")
    public static let fan1Max = SMCKey("F1Mx")
}

/// Static metadata for an SMC key.
public struct SMCKeyInfo: Sendable {
    public let dataSize: UInt32
    public let dataType: UInt32  // also a 4-CC, e.g. "flt ", "fp1f", "ui32"
    public let dataAttributes: UInt8

    public var typeString: String {
        SMCKey(raw: dataType).fourCC
    }
}

extension SMCKey {
    fileprivate init(raw: UInt32) {
        self.raw = raw
    }
}

/// A live connection to `AppleSMC`. Open once at app launch, share
/// across collectors, close in `deinit`. All public methods are
/// thread-safe via an internal serial queue (the SMC kernel
/// connection is not safe to use concurrently).
///
/// Prefer `SMCBridge.shared` over constructing manually; collectors
/// share one kernel connection rather than each opening their own.
public final class SMCBridge: @unchecked Sendable {
    private let connection: io_connect_t
    private let queue = DispatchQueue(label: "com.crafcat7.Peakmon.smc")

    /// Cache of static per-key metadata (`dataSize` / `dataType` /
    /// `dataAttributes`). Populated lazily on the first `info(_:)`
    /// or `readDouble(_:)` for a given key.
    ///
    /// SMC key metadata is *static* for the life of the running
    /// kernel — the type and width of `PSTR` does not change between
    /// reads. Without this cache `readDouble` paid **three**
    /// `IOConnectCallStructMethod` round-trips per value (info →
    /// readBytes-internal info → readBytes), turning a 10-key 1 Hz
    /// dashboard into 30 SMC syscalls per second. With it the
    /// steady-state cost drops to one syscall per value (just the
    /// actual `readBytes`).
    ///
    /// Only mutated inside `queue.sync`, so the unsynchronised
    /// dictionary is safe even though the type is nominally
    /// `@unchecked Sendable`.
    private var keyInfoCache: [SMCKey: SMCKeyInfo] = [:]

    /// Process-wide shared bridge. `nil` if `AppleSMC` is not
    /// available (stripped VM, future macOS removal, …). Lazy:
    /// constructing it does an `IOServiceOpen`, so callers that
    /// never read SMC pay no cost.
    public static let shared: SMCBridge? = {
        do {
            return try SMCBridge()
        } catch {
            return nil
        }
    }()

    /// Open a connection to AppleSMC. Throws if the service is not
    /// matched (e.g. running in a stripped VM) or `IOServiceOpen`
    /// fails. Prefer `SMCBridge.shared` in production code.
    public init() throws {
        // Frozen since macOS 10.6; assert the layout invariant so
        // any future tuple/field reshuffle fails loudly in debug
        // rather than silently corrupting SMC reads in release.
        assert(
            MemoryLayout<SMCParamStruct>.size == 80,
            "SMCParamStruct layout drift — kernel ABI assumes 80 bytes",
        )
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC"),
        )
        guard service != 0 else {
            throw SMCError.openFailed(kIOReturnNotFound)
        }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard kr == kIOReturnSuccess else {
            throw SMCError.openFailed(kr)
        }
        self.connection = conn
    }

    deinit {
        IOServiceClose(connection)
    }

    /// Read static type/size metadata for `key`. Used to probe whether
    /// a key exists on this machine before bothering to read it.
    ///
    /// Results are memoised in `keyInfoCache` (see the field doc on
    /// why this is safe) so repeat calls for the same key cost zero
    /// syscalls. A cache miss issues exactly one `readKeyInfo`
    /// command and stores the result before returning.
    public func info(_ key: SMCKey) throws -> SMCKeyInfo {
        try queue.sync {
            try cachedInfoLocked(key)
        }
    }

    /// Queue-internal cached lookup. Caller MUST already be inside
    /// `queue.sync`; this is the single place that mutates
    /// `keyInfoCache`.
    private func cachedInfoLocked(_ key: SMCKey) throws -> SMCKeyInfo {
        if let cached = keyInfoCache[key] {
            return cached
        }
        var input = SMCParamStruct()
        input.key = key.raw
        input.data8 = Command.readKeyInfo
        let output = try call(input)
        let info = SMCKeyInfo(
            dataSize: output.keyInfo.dataSize,
            dataType: output.keyInfo.dataType,
            dataAttributes: output.keyInfo.dataAttributes,
        )
        keyInfoCache[key] = info
        return info
    }

    /// Returns the key's raw value bytes (up to 32). Use the typed
    /// `read(_ key:as:)` helpers below in most code.
    ///
    /// Issues at most one extra `readKeyInfo` per *unfamiliar* key
    /// (cached afterwards) and then exactly one `readBytes` per
    /// call; previous revisions paid for the `readKeyInfo` on every
    /// invocation.
    public func readBytes(_ key: SMCKey) throws -> Data {
        try queue.sync {
            let info = try cachedInfoLocked(key)
            return try readBytesLocked(key, info: info)
        }
    }

    /// Queue-internal byte read that assumes the caller has already
    /// resolved `SMCKeyInfo` (typically via `cachedInfoLocked`).
    /// Caller MUST already be inside `queue.sync`.
    private func readBytesLocked(_ key: SMCKey, info: SMCKeyInfo) throws -> Data {
        let size = Int(info.dataSize)
        guard size > 0, size <= 32 else {
            throw SMCError.keyNotFound(key)
        }
        // AppleSMC's `readBytes` command (data8 = 5) only validates
        // `dataSize`; the dataType field is ignored by the kernel
        // and intentionally left zero here (matches stats, iStats,
        // SMCKit, libsmc).
        var read = SMCParamStruct()
        read.key = key.raw
        read.keyInfo.dataSize = info.dataSize
        read.data8 = Command.readBytes
        let result = try call(read)
        return withUnsafeBytes(of: result.bytes) { raw in
            Data(raw.prefix(size))
        }
    }

    /// Read `key` and decode as `Double`, regardless of underlying
    /// SMC numeric type (`flt`, `fp*`, `sp*`, `ui8/16/32`, `si16`).
    /// Throws `unsupportedType` for unknown type codes.
    ///
    /// Steady-state cost: **one** `IOConnectCallStructMethod` per
    /// call (the actual `readBytes`). The key's metadata round-trip
    /// happens once per process lifetime via `keyInfoCache`.
    public func readDouble(_ key: SMCKey) throws -> Double {
        let (info, bytes) = try queue.sync { () -> (SMCKeyInfo, Data) in
            let info = try cachedInfoLocked(key)
            let bytes = try readBytesLocked(key, info: info)
            return (info, bytes)
        }
        let type = info.typeString

        if let fmt = Self.fixedPointFormats[type] {
            return Self.decodeFixedPoint(bytes, fracBits: fmt.fracBits, signed: fmt.signed)
        }
        switch type {
        case "flt ":
            // `flt ` is the one SMC numeric type that is stored in
            // host (little-endian on Apple Silicon / Intel)
            // byte order — every other numeric type below is
            // big-endian. Confirmed empirically on M-series Macs:
            // PSTR reads as sensible single-digit watts when loaded
            // little-endian and as 1e20+ garbage when byte-swapped.
            return Double(bytes.withUnsafeBytes { $0.load(as: Float.self) })
        case "ui8 ": return Double(bytes[0])
        case "ui16":
            return Double(bytes.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian })
        case "ui32":
            return Double(bytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        case "si16":
            return Double(bytes.withUnsafeBytes { $0.load(as: Int16.self).bigEndian })
        default:
            throw SMCError.unsupportedType(key, type: type)
        }
    }

    /// SMC fixed-point type codes follow a pattern: the trailing hex
    /// digit is the fractional bit count, the second-to-last digit
    /// is the integer bit count, and `fp` / `sp` denote unsigned /
    /// signed. We only care about `fracBits` + signedness here
    /// because the payload is always 16 bits wide.
    private static let fixedPointFormats: [String: (fracBits: Int, signed: Bool)] = [
        "fp1f": (15, false), "fp2e": (14, false), "fp4c": (12, false),
        "fp5b": (11, false), "fp6a": (10, false), "fp79": (9, false),
        "fp88": (8, false), "fpa6": (6, false), "fpc4": (4, false),
        "fpe2": (2, false),
        "sp1e": (14, true), "sp78": (8, true), "sp87": (7, true),
        "sp96": (6, true), "spa5": (5, true), "spb4": (4, true),
        "spf0": (0, true),
    ]

    // MARK: - Diagnostics

    /// One-shot probe of a curated set of power-related keys; emits
    /// `(key, type, value-or-error)` rows ordered as input. Used by
    /// SystemPowerCollector to write a diagnostic dump on first
    /// launch so users on unfamiliar hardware can mail us the
    /// concrete SMC capabilities of their machine.
    public func probe(_ keys: [SMCKey]) -> [(SMCKey, String, Result<Double, Error>)] {
        keys.map { key in
            do {
                let info = try info(key)
                let value = try readDouble(key)
                return (key, info.typeString, .success(value))
            } catch {
                return (key, "—", .failure(error))
            }
        }
    }

    // MARK: - Private

    private enum Command {
        static let readBytes: UInt8 = 5
        static let readKeyInfo: UInt8 = 9
    }

    /// User-mode selector index that AppleSMC's HID-style command
    /// interface exposes for "read parameter struct, returning
    /// parameter struct". Stable since 10.6 (kSMCUCKeyCommand).
    private static let kSMCHandleYPCEvent: UInt32 = 2

    private func call(_ input: SMCParamStruct) throws -> SMCParamStruct {
        var inStruct = input
        var outStruct = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.size
        let kr = IOConnectCallStructMethod(
            connection,
            Self.kSMCHandleYPCEvent,
            &inStruct,
            MemoryLayout<SMCParamStruct>.size,
            &outStruct,
            &outSize,
        )
        guard kr == kIOReturnSuccess else {
            throw SMCError.callFailed(kr, command: input.data8)
        }
        if outStruct.result == 0x84 {
            // kSMCKeyNotFound — caller-facing.
            throw SMCError.keyNotFound(SMCKey(raw: input.key))
        }
        if outStruct.result != 0 {
            throw SMCError.callFailed(
                kern_return_t(outStruct.result),
                command: input.data8,
            )
        }
        return outStruct
    }

    /// Generic fixed-point decoder used by every `fp*` / `sp*` type.
    /// The 2-byte payload is big-endian; the low `fracBits` are the
    /// fractional part, everything above is integer (and sign-bit
    /// for `sp*`).
    private static func decodeFixedPoint(
        _ data: Data,
        fracBits: Int,
        signed: Bool,
    ) -> Double {
        guard data.count >= 2 else { return 0 }
        let raw = data.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        if signed {
            return Double(Int16(bitPattern: raw)) / Double(1 << fracBits)
        }
        return Double(raw) / Double(1 << fracBits)
    }
}

// MARK: - SMC parameter struct

/// User-mode mirror of `kern/SMCParamStruct.h`. Layout has been frozen
/// since 10.6; total size 80 bytes. We only populate `key`, `data8`
/// and `keyInfo.dataSize` for the two commands we use (read-key-info,
/// read-bytes).
private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers: SMCVersion = SMCVersion()
    var pLimitData: SMCPLimitData = SMCPLimitData()
    var keyInfo: SMCKeyInfoData = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCByteBuffer = SMCByteBuffer()
}

private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

/// 32-byte inline buffer for SMC key bytes. Modelled as a tuple to
/// preserve the C struct's contiguous layout.
private struct SMCByteBuffer {
    // swiftlint:disable:next large_tuple
    var storage: (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    ) = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )
}
