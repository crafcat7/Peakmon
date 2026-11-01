import PeakmonCore

/// Selects only known chip families; future names must not inherit an older map.
enum SMCThermalPlatform: Equatable, Sendable {
    case intel
    case m1
    case m2
    case m3
    case m4
    case m4Pro
    case m4Max
    case m5
    case unknown

    init(cpuBrand: String) {
        let words = cpuBrand.lowercased().split(whereSeparator: \.isWhitespace)
        if words.first == "intel" || words.first == "intel(r)" {
            self = .intel
            return
        }
        guard words.count == 2 || words.count == 3, words[0] == "apple" else {
            self = .unknown
            return
        }
        let variant = words.count == 3 ? String(words[2]) : ""
        guard ["", "pro", "max", "ultra"].contains(variant) else {
            self = .unknown
            return
        }
        switch words[1] {
        case "m1": self = .m1
        case "m2": self = .m2
        case "m3": self = .m3
        case "m4":
            switch variant {
            case "": self = .m4
            case "pro": self = .m4Pro
            case "max": self = .m4Max
            default: self = .unknown
            }
        case "m5": self = .m5
        default: self = .unknown
        }
    }
}

/// Candidate die sensors, grouped by hardware family rather than key prefix.
/// A candidate may be absent on a smaller chip; successful reads establish support.
/// Hardware key references (no external implementation is incorporated):
/// https://github.com/exelban/stats/blob/683a0581d42839969ab21c14659f23d6054bb618/Modules/Sensors/values.swift
/// https://github.com/narugit/smctemp/blob/34a3381687c0d0b7767c53ce1bd23e78f689026e/smctemp.cc
struct SMCThermalSensors: Sendable {
    let cpu: [SMCKey]
    let gpu: [SMCKey]

    static func sensors(for platform: SMCThermalPlatform) -> Self {
        switch platform {
        case .intel:
            return Self(
                cpu: ["TC0D", "TC0E", "TC0F", "TCAD"],
                gpu: ["TCGC", "TG0D", "TGDD"],
            )
        case .m1:
            return Self(
                cpu: [
                    "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
                ],
                gpu: ["Tg05", "Tg0D", "Tg0L", "Tg0T"],
            )
        case .m2:
            return Self(
                cpu: [
                    "Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j",
                ],
                gpu: ["Tg0f", "Tg0j"],
            )
        case .m3:
            return Self(
                cpu: [
                    "Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B",
                    "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
                ],
                gpu: ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"],
            )
        case .m4, .m4Pro, .m4Max:
            let variantGPU = platform == .m4 ? ["Tg0G", "Tg0H"] : ["Tg1U", "Tg1k"]
            return Self(
                cpu: [
                    "Te05", "Te09", "Te0H", "Te0S", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e",
                ],
                gpu: variantGPU + ["Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"],
            )
        case .m5:
            return Self(
                cpu: [
                    "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U",
                    "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y",
                ],
                gpu: ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"],
            )
        case .unknown:
            // Preserve the previous candidates without borrowing another generation.
            return Self(
                cpu: ["Tp01", "Tp05", "Tp09", "Tp0D"],
                gpu: ["Tg05", "Tg0D"],
            )
        }
    }

    private init(cpu: [String], gpu: [String]) {
        self.cpu = cpu.map(SMCKey.init)
        self.gpu = gpu.map(SMCKey.init)
    }
}
