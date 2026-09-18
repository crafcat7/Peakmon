import Foundation
import PeakmonCore

/// Chip-specific SMC supply readings. These scopes are independent of the
/// IOReport Energy Model rails and must not replace or supplement their totals.
/// M3 Max mapping: https://github.com/asto18089/apple_smc_thoughts
/// Backlight/DRAM experiments: https://github.com/ianm199/smcprobe
/// Independently exercised on Mac15,9; do not extend to other chips without
/// hardware validation. SMC supply and IOReport model values are not additive.
struct M3MaxPowerRails {
    static let gpuClusterKeys = ["PC10", "PC12", "PC20", "PC22"]
    static let gpuSharedKey = "PC40"
    static let dramSupplyKey = "PMVC"
    static let displayBacklightKey = "PDBR"

    /// Stable read order; each hardware key is sampled once per collection.
    static let allKeys = gpuClusterKeys + [gpuSharedKey, dramSupplyKey, displayBacklightKey]

    private static let rails: [(kind: MetricKind, keys: [String])] = [
        (.powerGPUClusters, gpuClusterKeys),
        (.powerGPUShared, [gpuSharedKey]),
        (.powerDRAMSupply, [dramSupplyKey]),
        (.powerDisplayBacklight, [displayBacklightKey]),
    ]

    static func samples(
        chip: String,
        readings: [String: Double],
        timestamp: Date,
    ) -> [MetricSample] {
        rails.map { rail in
            guard chip == "Apple M3 Max",
                  let watts = total(keys: rail.keys, readings: readings)
            else {
                return .unavailable(kind: rail.kind, unit: .watts, timestamp: timestamp)
            }
            return MetricSample(kind: rail.kind, unit: .watts, value: watts, timestamp: timestamp)
        }
    }

    private static func total(keys: [String], readings: [String: Double]) -> Double? {
        var watts = 0.0
        for key in keys {
            guard let value = readings[key], value.isFinite, value >= 0 else { return nil }
            watts += value
        }
        return watts.isFinite ? watts : nil
    }
}
