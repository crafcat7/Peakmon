//
//  ThermalCollector.swift
//  PeakmonCollectors
//
//  Reads a curated, chip-specific set of CPU/GPU SMC temperature sensors.
//  The headline value is the hottest valid sensor in the selected set,
//  a Peakmon presentation choice rather than an Apple-defined die metric.
//  Proximity sensors are used only when no valid die reading is available.
//

import Darwin
import Foundation
import PeakmonCore

/// Samples the hottest available mapped CPU/GPU temperature in Celsius.
public final class ThermalCollector: MetricCollector {
    public let identifier = "thermal.smc"

    private let state: State

    public init() {
        state = State(cpuBrand: Self.cpuBrand(), bridge: SMCBridge.shared)
    }

    init(cpuBrand: String, bridge: (any SMCThermalReading)?) {
        state = State(cpuBrand: cpuBrand, bridge: bridge)
    }

    public func collect() async throws -> [MetricSample] {
        await state.sample(at: .now)
    }

    func collect(at timestamp: Date) async -> [MetricSample] {
        await state.sample(at: timestamp)
    }

    private static func cpuBrand() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0,
              size > 0, size <= 1_024 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private actor State {
        private let bridge: (any SMCThermalReading)?
        private let sensors: SMCThermalSensors
        private var retryAfter: [SMCKey: Date] = [:]

        init(cpuBrand: String, bridge: (any SMCThermalReading)?) {
            self.bridge = bridge
            sensors = .sensors(for: SMCThermalPlatform(cpuBrand: cpuBrand))
        }

        func sample(at timestamp: Date) -> [MetricSample] {
            let cpu = maxReading(sensors.cpu, at: timestamp)
                ?? reading(.cpuProximity, at: timestamp)
            let gpu = maxReading(sensors.gpu, at: timestamp)
                ?? reading(.gpuProximity, at: timestamp)
            return [
                sample(kind: .thermalCPU, value: cpu, at: timestamp),
                sample(kind: .thermalGPU, value: gpu, at: timestamp),
            ]
        }

        private func sample(kind: MetricKind, value: Double?, at timestamp: Date) -> MetricSample {
            guard let value else {
                return .unavailable(kind: kind, unit: .celsius, timestamp: timestamp)
            }
            return MetricSample(kind: kind, unit: .celsius, value: value, timestamp: timestamp)
        }

        private func maxReading(_ keys: [SMCKey], at timestamp: Date) -> Double? {
            var hottest: Double?
            for key in keys {
                if let value = reading(key, at: timestamp) {
                    hottest = max(hottest ?? value, value)
                }
            }
            return hottest
        }

        private func reading(_ key: SMCKey, at timestamp: Date) -> Double? {
            guard let bridge,
                  retryAfter[key].map({ timestamp >= $0 }) ?? true else { return nil }
            do {
                let value = try bridge.readDouble(key)
                retryAfter.removeValue(forKey: key)
                return value.isFinite && value > 0 && value < 150 ? value : nil
            } catch let error as SMCError {
                switch error {
                case .keyNotFound, .unsupportedType:
                    // Smaller dies omit some mapped keys. Bound repeated failed
                    // probes, but allow an initially unavailable key to recover.
                    retryAfter[key] = timestamp.addingTimeInterval(30)
                default:
                    break // Retry transient connection/read failures next tick.
                }
                return nil
            } catch {
                return nil
            }
        }
    }
}

/// Internal seam for deterministic sensor tests.
protocol SMCThermalReading: Sendable {
    func readDouble(_ key: SMCKey) throws -> Double
}

extension SMCBridge: SMCThermalReading {}
