//
//  PowerCollector.swift
//  PeakmonCollectors
//
//  IOReport energy deltas provide CPU / GPU / memory / display watts.
//  On some macOS 27 hosts the legacy mJ provider remains subscribable
//  but stops advancing. Keep live GPU Energy (nJ) and report unavailable
//  legacy rails explicitly instead of publishing fabricated zero watts.
//
//  M3 Max has a separately validated SMC CPU supply reading. Its scope stays
//  distinct from the IOReport CPU Energy metric. These key meanings are
//  chip-specific; never enable this mapping for another SoC by name prefix
//  or substitute PHPC (thermal-control power) for CPU power.
//

import Foundation
import PeakmonCore

public final class PowerCollector: ResettableMetricCollector {
    public let identifier = "power.ioreport"
    private let state = State()

    public init() {}

    public func collect() async throws -> [MetricSample] {
        await state.sample()
    }

    public func reset() async {
        await state.reset()
    }

    // Validated on M3 Max with separate CPU and GPU loads. See:
    // https://github.com/vladkens/macmon/pull/77
    // P0 core/misc + P1 core/misc + E cluster, excluding GPU/DRAM.
    static let m3MaxCPUKeys = ["PC02", "PC03", "PC42", "PC43", "PP5b"]

    static func m3MaxCPUWatts(chip: String, values: [Double?]) -> Double? {
        guard chip == "Apple M3 Max", values.count == m3MaxCPUKeys.count else { return nil }
        var total = 0.0
        for value in values {
            guard let value, value.isFinite, value >= 0 else { return nil }
            total += value
        }
        return total.isFinite ? total : nil
    }

    static func m3MaxCPUSupplySample(_ watts: Double?, at timestamp: Date) -> MetricSample {
        guard let watts, watts.isFinite, watts >= 0 else {
            return .unavailable(kind: .powerCPUSupply, unit: .watts, timestamp: timestamp)
        }
        return MetricSample(kind: .powerCPUSupply, unit: .watts, value: watts, timestamp: timestamp)
    }

    private static func chipName() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private actor State {
        private static let smcSampleCount = 8
        private static let smcSampleInterval = Duration.milliseconds(250)

        private var bridge: IOReportBridge?
        private var bridgeAttempted = false
        private var previous: IOReportBridge.Snapshot?
        private var previousAt: Date?
        private var resolver = FrameResolver()
        private let chip = PowerCollector.chipName()
        private let smc = SMCBridge.shared

        func sample() async -> [MetricSample] {
            if !bridgeAttempted {
                bridgeAttempted = true
                bridge = try? IOReportBridge(group: "Energy Model")
            }
            let smcReadings = await averagedSMCReadings()
            let now = Date.now
            var readings: [IOReportBridge.Reading] = []
            var elapsed = 0.0
            if let snapshot = try? bridge?.snapshot() {
                if let previous, let previousAt {
                    elapsed = now.timeIntervalSince(previousAt)
                    readings = snapshot.delta(against: previous)
                }
                previous = snapshot
                previousAt = now
            } else {
                // Do not average over a failed sampling window when it recovers.
                previous = nil
                previousAt = nil
            }

            var samples = resolver.samples(readings: readings, elapsed: elapsed, timestamp: now)
            let cpuSupply = PowerCollector.m3MaxCPUWatts(
                chip: chip,
                values: PowerCollector.m3MaxCPUKeys.map { smcReadings[$0] },
            )
            samples.append(PowerCollector.m3MaxCPUSupplySample(cpuSupply, at: now))
            // Physical SMC supply readings retain their own metric kinds:
            // neither GPU supply nor backlight is an IOReport sub-rail.
            samples += M3MaxPowerRails.samples(chip: chip, readings: smcReadings, timestamp: now)
            samples.append(SystemPowerCollector.makeSample(
                value: smcReadings[SMCKey.systemTotal.fourCC],
                timestamp: now,
            ))
            return samples
        }

        /// SMC rate keys refresh more slowly than a single host call. Read a
        /// full foreground window so the published value is not whichever
        /// point happened to be visible at the scheduler boundary.
        private func averagedSMCReadings() async -> [String: Double] {
            guard let smc else { return [:] }
            let keys = chip == "Apple M3 Max"
                ? [SMCKey.systemTotal.fourCC] + PowerCollector.m3MaxCPUKeys + M3MaxPowerRails.allKeys
                : [SMCKey.systemTotal.fourCC]
            var frames: [[String: Double]] = []
            frames.reserveCapacity(Self.smcSampleCount)
            for index in 0..<Self.smcSampleCount {
                var frame: [String: Double] = [:]
                for key in keys {
                    if let value = try? smc.readDouble(SMCKey(key)) {
                        frame[key] = value
                    }
                }
                frames.append(frame)
                if index < Self.smcSampleCount - 1 {
                    do {
                        try await Task.sleep(for: Self.smcSampleInterval)
                    } catch {
                        return [:]
                    }
                }
            }
            return PowerCollector.averageSMCFrames(frames, keys: keys)
        }

        func reset() {
            previous = nil
            previousAt = nil
            resolver = FrameResolver()
        }
    }

    static func averageSMCFrames(
        _ frames: [[String: Double]],
        keys: [String],
    ) -> [String: Double] {
        guard !frames.isEmpty else { return [:] }
        var result: [String: Double] = [:]
        for key in keys {
            let values = frames.compactMap { $0[key] }
            guard values.count == frames.count,
                  values.allSatisfy({ $0.isFinite && $0 >= 0 })
            else { continue }
            let total = values.reduce(0, +)
            let average = total / Double(values.count)
            if average.isFinite { result[key] = average }
        }
        return result
    }

    /// The legacy provider is considered live only after observing an
    /// increment. Three consecutive entirely motionless mJ windows revoke
    /// that evidence. Individual idle rails can still correctly report zero
    /// while their provider is live. A later increment restores availability.
    struct FrameResolver {
        private var observedLegacyActivity = false
        private var zeroLegacyWindows = 0

        mutating func samples(
            readings: [IOReportBridge.Reading],
            elapsed: TimeInterval,
            timestamp: Date,
        ) -> [MetricSample] {
            let kinds: [MetricKind] = [
                .powerCPU, .powerGPU, .powerGPUCore, .powerGPUCommandStreamer,
                .powerGPUSRAM, .powerDRAM, .powerDisplay, .powerPackage,
            ]
            guard elapsed.isFinite, elapsed > 0, !readings.isEmpty else {
                observedLegacyActivity = false
                zeroLegacyWindows = 0
                return kinds.map { .unavailable(kind: $0, unit: .watts, timestamp: timestamp) }
            }

            let legacyMoves = readings.contains { $0.unit == "mJ" && $0.value > 0 }
            if legacyMoves {
                observedLegacyActivity = true
                zeroLegacyWindows = 0
            } else {
                zeroLegacyWindows = min(3, zeroLegacyWindows + 1)
            }
            let legacyAvailable = observedLegacyActivity && zeroLegacyWindows < 3
            var energies: [MetricKind: Double] = [:]
            var cpuSummary: Double?
            var gpuSummary: Double?
            var cpuLeaves: Double?
            var invalidKinds: Set<MetricKind> = []
            var invalidCPUSummary = false
            var invalidCPULeaves = false
            var invalidGPUSummary = false

            for reading in readings {
                guard let scale = Self.joulesPerUnit(reading.unit) else { continue }
                let name = Self.channelName(reading.channel)
                let base = String(name.reversed().drop(while: { $0.isNumber }).reversed())
                let isCPULeaf = (name.hasPrefix("EACC_CPU") || name.hasPrefix("PACC"))
                    && name != "EACC_CPU"
                    && !(name.hasPrefix("PACC") && name.hasSuffix("_CPU"))
                let detailKind: MetricKind? = switch base {
                case "GPU": .powerGPUCore
                case "GPU CS": .powerGPUCommandStreamer
                case "GPU SRAM", "GPU CS SRAM": .powerGPUSRAM
                case "DCS", "DRAM", "AMCC": .powerDRAM
                case "DISP", "DISPEXT": .powerDisplay
                default: nil
                }
                guard reading.value >= 0 else {
                    // A reset/sentinel in one constituent invalidates its
                    // total; never present the remaining rails as complete.
                    if name == "CPU Energy" { invalidCPUSummary = true }
                    if name == "GPU Energy" { invalidGPUSummary = true }
                    if isCPULeaf { invalidCPULeaves = true }
                    if let detailKind { invalidKinds.insert(detailKind) }
                    continue
                }
                let energy = Double(reading.value) * scale
                // A stale mJ provider must not override live nJ summaries.
                guard reading.unit != "mJ" || legacyAvailable else { continue }
                if name == "CPU Energy" {
                    cpuSummary = (cpuSummary ?? 0) + energy
                } else if name == "GPU Energy" {
                    gpuSummary = (gpuSummary ?? 0) + energy
                } else if isCPULeaf {
                    cpuLeaves = (cpuLeaves ?? 0) + energy
                } else if let detailKind {
                    energies[detailKind, default: 0] += energy
                }
            }

            for kind in invalidKinds { energies[kind] = nil }
            if invalidCPUSummary { cpuSummary = nil }
            if invalidCPULeaves { cpuLeaves = nil }
            if invalidGPUSummary { gpuSummary = nil }
            energies[.powerCPU] = (cpuSummary ?? 0) > 0 ? cpuSummary : (cpuLeaves ?? cpuSummary)
            let gpuKinds: Set<MetricKind> = [.powerGPUCore, .powerGPUCommandStreamer, .powerGPUSRAM]
            let gpuDetails = gpuKinds.compactMap { energies[$0] }
            let gpuTotal = gpuDetails.isEmpty || !gpuKinds.isDisjoint(with: invalidKinds) ? nil : gpuDetails.reduce(0, +)
            energies[.powerGPU] = (gpuTotal ?? 0) > 0 ? gpuTotal : (gpuSummary ?? gpuTotal)
            if let cpu = energies[.powerCPU], let gpu = energies[.powerGPU] {
                energies[.powerPackage] = cpu + gpu
            }
            return kinds.map { kind in
                guard let energy = energies[kind], (energy / elapsed).isFinite else {
                    return .unavailable(kind: kind, unit: .watts, timestamp: timestamp)
                }
                return MetricSample(kind: kind, unit: .watts, value: energy / elapsed, timestamp: timestamp)
            }
        }

        private static func joulesPerUnit(_ unit: String) -> Double? {
            switch unit {
            case "J": 1
            case "mJ": 1e-3
            case "uJ", "µJ", "μJ": 1e-6
            case "nJ": 1e-9
            default: nil
            }
        }

        /// Multi-die providers can prefix names, e.g. "DIE0 GPU0".
        private static func channelName(_ raw: String) -> String {
            let parts = raw.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].hasPrefix("DIE"),
               !parts[0].dropFirst(3).isEmpty, parts[0].dropFirst(3).allSatisfy(\.isNumber) {
                return String(parts[1])
            }
            return raw
        }
    }
}
