//
//  GPUCollector.swift
//  PeakmonCollectors
//
//  Reports GPU utilization (Device / Renderer / Tiler) by reading the
//  `PerformanceStatistics` CFDictionary exposed by IOKit's
//  `IOAccelerator` service class. The same path is used by Apple's
//  Activity Monitor and well-known OSS tools (stats, mactop, iStats);
//  it is public API, signs cleanly, and works on Intel, AMD, and
//  Apple Silicon GPUs alike.
//
//  Apple Silicon machines may expose more than one IOAccelerator node
//  (e.g. a real GPU + a wired display accelerator). The collector
//  picks the entry with the highest "Device Utilization %" so a
//  busy iGPU is not masked by an idle helper service.
//
//  Public API of PeakmonCollectors — no private/SPI usage.
//

import Foundation
import IOKit
import PeakmonCore

/// Static, one-shot description of the host's primary GPU. Read once
/// from the IOAccelerator entry that the dynamic `GPUCollector` later
/// samples for utilization. Both fields are optional because not every
/// driver (e.g. some VMs) populates them.
public struct GPUDeviceInfo: Sendable, Hashable {
    public let model: String?
    public let coreCount: Int?

    public init(model: String?, coreCount: Int?) {
        self.model = model
        self.coreCount = coreCount
    }
}

/// Samples GPU utilization for the host's primary accelerator.
public final class GPUCollector: MetricCollector {
    public let identifier = "gpu.ioaccelerator"

    public init() {}

    /// Reads `model` and `gpu-core-count` from the first IOAccelerator
    /// entry that exposes them. Static information — call once at app
    /// launch and cache; the values do not change at runtime.
    public static func deviceInfo() -> GPUDeviceInfo {
        let matching = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else { return GPUDeviceInfo(model: nil, coreCount: nil) }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let model = property(entry: entry, key: "model")
                ?? property(entry: entry, key: "IOClass")
            let coreCount = numericProperty(entry: entry, key: "gpu-core-count")
            if model != nil || coreCount != nil {
                return GPUDeviceInfo(model: model, coreCount: coreCount)
            }
        }
        return GPUDeviceInfo(model: nil, coreCount: nil)
    }

    public func collect() async throws -> [MetricSample] {
        guard let stats = Self.readBestPerformanceStatistics() else {
            // No accelerator surfaced statistics this tick — happens on
            // some VMs and during the very first second after boot.
            // Returning [] (instead of throwing) keeps the scheduler
            // ticking quietly until the kext is ready.
            return []
        }
        let now = Date.now
        let device = Self.percent(stats["Device Utilization %"])
        let renderer = Self.percent(stats["Renderer Utilization %"])
        let tiler = Self.percent(stats["Tiler Utilization %"])

        return [
            MetricSample(kind: .gpuUtilization, unit: .percent, value: device, timestamp: now),
            MetricSample(kind: .gpuRenderer, unit: .percent, value: renderer, timestamp: now),
            MetricSample(kind: .gpuTiler, unit: .percent, value: tiler, timestamp: now),
        ]
    }

    // MARK: - Private

    /// Iterates every `IOAccelerator` service entry and returns the
    /// `PerformanceStatistics` dictionary belonging to the entry with
    /// the highest reported device utilization. This avoids picking a
    /// dormant secondary accelerator when the active one is busy.
    private static func readBestPerformanceStatistics() -> [String: Any]? {
        let matching = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var best: [String: Any]?
        var bestUtil: Double = -1

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = Self.readPerformanceStatistics(entry: entry) else { continue }
            let util = percent(stats["Device Utilization %"])
            if util > bestUtil {
                bestUtil = util
                best = stats
            }
        }
        return best
    }

    private static func readPerformanceStatistics(entry: io_registry_entry_t) -> [String: Any]? {
        guard let unmanaged = IORegistryEntryCreateCFProperty(
            entry,
            "PerformanceStatistics" as CFString,
            kCFAllocatorDefault,
            0,
        ) else { return nil }
        let value = unmanaged.takeRetainedValue()
        return value as? [String: Any]
    }

    /// Coerces the polymorphic CFDictionary values into a `Double`
    /// percent. PerformanceStatistics typically stores integers 0...100
    /// but some drivers report fractional doubles, so we accept both.
    private static func percent(_ raw: Any?) -> Double {
        if let int = raw as? Int { return Double(int) }
        if let double = raw as? Double { return double }
        if let number = raw as? NSNumber { return number.doubleValue }
        return 0
    }

    /// Reads a string-typed IORegistry property, handling the common
    /// case where Apple Silicon drivers store the value as `Data`
    /// (UTF-8, NUL-terminated) instead of `CFString`.
    private static func property(entry: io_registry_entry_t, key: String) -> String? {
        guard let unmanaged = IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0,
        ) else { return nil }
        let value = unmanaged.takeRetainedValue()
        if let string = value as? String { return string }
        if let data = value as? Data {
            // Apple Silicon `model` and `IOClass` come back as NUL-
            // terminated UTF-8 byte sequences inside a CFData blob.
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .controlCharacters)
        }
        return nil
    }

    private static func numericProperty(entry: io_registry_entry_t, key: String) -> Int? {
        guard let unmanaged = IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0,
        ) else { return nil }
        let value = unmanaged.takeRetainedValue()
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let data = value as? Data {
            // 32-bit little-endian integer stored as raw bytes.
            return data.withUnsafeBytes { raw -> Int? in
                guard raw.count >= 4 else { return nil }
                let value = raw.load(as: UInt32.self)
                return Int(UInt32(littleEndian: value))
            }
        }
        return nil
    }
}
