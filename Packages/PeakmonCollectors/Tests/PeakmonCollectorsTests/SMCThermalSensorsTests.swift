@testable import PeakmonCollectors
import PeakmonCore
import Testing

@Suite("SMC thermal sensor mappings")
struct SMCThermalSensorsTests {
    @Test func recognizesSupportedCPUBrandsAndVariants() {
        let fixtures: [(String, SMCThermalPlatform)] = [
            ("Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz", .intel),
            ("Intel Xeon W", .intel),
            ("Apple M1", .m1), ("Apple M1 Pro", .m1), ("Apple M1 Max", .m1), ("Apple M1 Ultra", .m1),
            ("Apple M2", .m2), ("Apple M2 Pro", .m2), ("Apple M2 Max", .m2), ("Apple M2 Ultra", .m2),
            ("Apple M3", .m3), ("Apple M3 Pro", .m3), ("Apple M3 Max", .m3), ("Apple M3 Ultra", .m3),
            ("Apple M4", .m4), ("Apple M4 Pro", .m4Pro), ("Apple M4 Max", .m4Max),
            ("Apple M5", .m5), ("Apple M5 Pro", .m5), ("Apple M5 Max", .m5), ("Apple M5 Ultra", .m5),
            ("  apple\tM5   pRo\n", .m5),
        ]
        for (brand, expected) in fixtures {
            #expect(SMCThermalPlatform(cpuBrand: brand) == expected)
        }
    }

    @Test(arguments: [
        "", "M1", "Mac15,9", "Apple", "Apple M0", "Apple M6", "Apple M10", "Apple M10 Pro",
        "Apple M1Pro", "Apple M5 Experimental", "Apple M5 Pro Extra", "Apple M4 Ultra",
        "NotApple M1", "NotIntel Core", "AMD Ryzen 9",
    ])
    func unknownBrandsCannotInheritKnownChipMappings(brand: String) {
        #expect(SMCThermalPlatform(cpuBrand: brand) == .unknown)
    }

    @Test func keepsM3CPUAndGPUSeparateDespiteSharedPrefix() {
        let sensors = SMCThermalSensors.sensors(for: .m3)
        #expect(Set(sensors.cpu).contains(SMCKey("Te05")))
        #expect(Set(sensors.cpu).contains(SMCKey("Tf04")))
        #expect(Set(sensors.cpu).contains(SMCKey("Tf4E")))
        #expect(Set(sensors.gpu).contains(SMCKey("Tf14")))
        #expect(Set(sensors.gpu).contains(SMCKey("Tf2A")))
        #expect(Set(sensors.cpu).isDisjoint(with: sensors.gpu))
        #expect(!sensors.cpu.contains(SMCKey("Tp01")))
        #expect(!sensors.gpu.contains(SMCKey("Tg05")))
    }

    @Test func selectsM4GPUVariantWithoutCombiningBothLayouts() {
        let base = SMCThermalSensors.sensors(for: .m4)
        let pro = SMCThermalSensors.sensors(for: .m4Pro)
        let max = SMCThermalSensors.sensors(for: .m4Max)
        #expect(base.cpu == pro.cpu && pro.cpu == max.cpu)
        #expect(pro.gpu == max.gpu)
        #expect(Set(base.gpu).subtracting(pro.gpu) == [SMCKey("Tg0G"), SMCKey("Tg0H")])
        #expect(Set(pro.gpu).subtracting(base.gpu) == [SMCKey("Tg1U"), SMCKey("Tg1k")])
        #expect(Set(base.gpu).intersection(pro.gpu).count == 6)
    }

    @Test func includesM5KeysWithTheirOriginalCase() {
        let sensors = SMCThermalSensors.sensors(for: .m5)
        #expect(sensors.cpu.count == 18)
        #expect(sensors.gpu.count == 8)
        #expect(sensors.cpu.contains(SMCKey("Tp00")))
        #expect(sensors.cpu.contains(SMCKey("Tp0d")))
        #expect(sensors.cpu.contains(SMCKey("Tp0y")))
        #expect(sensors.gpu.contains(SMCKey("Tg0U")))
        #expect(sensors.gpu.contains(SMCKey("Tg0d")))
        #expect(sensors.gpu.contains(SMCKey("Tg1g")))
        #expect(!sensors.cpu.contains(SMCKey("Tp0D")))
        #expect(!sensors.gpu.contains(SMCKey("Tg0D")))
        #expect(Set(sensors.cpu).isDisjoint(with: SMCThermalSensors.sensors(for: .unknown).cpu))
        #expect(Set(sensors.gpu).isDisjoint(with: SMCThermalSensors.sensors(for: .unknown).gpu))
    }

    @Test func retainsEarlierGenerationSensorFamilies() {
        let m1 = SMCThermalSensors.sensors(for: .m1)
        let m2 = SMCThermalSensors.sensors(for: .m2)
        #expect(m1.cpu.contains(SMCKey("Tp0T")))
        #expect(m1.gpu.contains(SMCKey("Tg0T")))
        #expect(m2.cpu.contains(SMCKey("Tp1h")))
        #expect(m2.cpu.contains(SMCKey("Tp1l")))
        #expect(m2.gpu.map(\.fourCC) == ["Tg0f", "Tg0j"])
        #expect(!m1.cpu.contains(SMCKey("Tp1h")))
        #expect(!m2.gpu.contains(SMCKey("Tg05")))
    }

    @Test func unknownHardwareKeepsOnlyThePreviousCandidates() {
        let sensors = SMCThermalSensors.sensors(for: .unknown)
        #expect(sensors.cpu.map(\.fourCC) == ["Tp01", "Tp05", "Tp09", "Tp0D"])
        #expect(sensors.gpu.map(\.fourCC) == ["Tg05", "Tg0D"])
    }

    @Test(arguments: [
        SMCThermalPlatform.intel, .m1, .m2, .m3, .m4, .m4Pro, .m4Max, .m5, .unknown,
    ])
    func candidatesAreUniqueAndLeaveProximityFallbackSeparate(platform: SMCThermalPlatform) {
        let sensors = SMCThermalSensors.sensors(for: platform)
        #expect(Set(sensors.cpu).count == sensors.cpu.count)
        #expect(Set(sensors.gpu).count == sensors.gpu.count)
        #expect(Set(sensors.cpu).isDisjoint(with: sensors.gpu))
        #expect(!sensors.cpu.contains(.cpuProximity))
        #expect(!sensors.gpu.contains(.gpuProximity))
    }
}
