import Foundation
@testable import PeakmonCore
import Testing

@Suite("SMC numeric decoding")
struct SMCBridgeDecodingTests {
    private let key = SMCKey("TEST")

    private func decode(_ type: String, bytes: [UInt8]) throws -> Double {
        try SMCBridge.decodeDouble(
            Data(bytes),
            for: key,
            info: SMCKeyInfo(dataSize: UInt32(bytes.count), dataType: SMCKey(type).raw),
        )
    }

    @Test func floatsUseLittleEndian() throws {
        #expect(try decode("flt ", bytes: [0x00, 0x00, 0x56, 0x42]) == 53.5)
        #expect(try decode("flt ", bytes: [0x00, 0x00, 0x20, 0xC0]) == -2.5)
    }

    @Test func fixedPointUsesBigEndianAndPreservesSign() throws {
        #expect(try decode("sp78", bytes: [0x37, 0x80]) == 55.5)
        #expect(try decode("sp78", bytes: [0xFF, 0x80]) == -0.5)
        #expect(try decode("fp2e", bytes: [0x60, 0x00]) == 1.5)
    }

    @Test func integersUseBigEndianAndPreserveSign() throws {
        #expect(try decode("ui8 ", bytes: [0xFF]) == 255)
        #expect(try decode("ui16", bytes: [0x12, 0x34]) == 4_660)
        #expect(try decode("ui32", bytes: [0x01, 0x02, 0x03, 0x04]) == 16_909_060)
        #expect(try decode("si16", bytes: [0xFE, 0xC0]) == -320)
    }

    @Test func slicedDataDoesNotRequireAlignedStorageOrZeroStartIndex() throws {
        let bytes = Data([0xFF, 0x00, 0x00, 0x56, 0x42]).dropFirst()
        #expect(try SMCBridge.decodeDouble(
            bytes,
            for: key,
            info: SMCKeyInfo(dataSize: 4, dataType: SMCKey("flt ").raw),
        ) == 53.5)
    }

    @Test func truncatedNumericPayloadsThrowInsteadOfLoadingOrReturningZero() {
        let numericWidths = [
            ("flt ", 4), ("sp78", 2), ("fp2e", 2), ("ui8 ", 1),
            ("ui16", 2), ("ui32", 4), ("si16", 2),
        ]
        for (type, width) in numericWidths {
            for actualWidth in 0 ..< width {
                #expect(throws: SMCError.self) {
                    try SMCBridge.decodeDouble(
                        Data(repeating: 0, count: actualWidth),
                        for: key,
                        info: SMCKeyInfo(dataSize: UInt32(width), dataType: SMCKey(type).raw),
                    )
                }
            }
        }
    }

    @Test func metadataWidthMustMatchTheNumericType() {
        #expect(throws: SMCError.self) {
            try SMCBridge.decodeDouble(
                Data([0, 0, 0, 0]),
                for: key,
                info: SMCKeyInfo(dataSize: 2, dataType: SMCKey("flt ").raw),
            )
        }
        #expect(throws: SMCError.self) {
            try decode("sp78", bytes: [0, 0, 0, 0])
        }
    }

    @Test func unknownTypeReportsItsKeyAndType() {
        do {
            _ = try decode("ch8*", bytes: [1, 2, 3, 4])
            Issue.record("An unknown numeric type was accepted")
        } catch SMCError.unsupportedType(let failedKey, let type) {
            #expect(failedKey == key)
            #expect(type == "ch8*")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Suite("SMC read-only key enumeration")
struct SMCBridgeEnumerationTests {
    private let countInfo = SMCKeyInfo(dataSize: 4, dataType: SMCKey("ui32").raw)

    private func countBytes(_ count: UInt32) -> Data {
        Data([
            UInt8((count >> 24) & 0xFF), UInt8((count >> 16) & 0xFF),
            UInt8((count >> 8) & 0xFF), UInt8(count & 0xFF),
        ])
    }

    @Test func decodesBigEndianCountAndPreservesFirmwareOrder() throws {
        let expected = [SMCKey("Tg05"), SMCKey("Tp05"), SMCKey("#KEY")]
        var indices: [UInt32] = []
        let keys = try SMCBridge.enumeratedKeys(countInfo: countInfo, countBytes: countBytes(3)) { index in
            indices.append(index)
            return expected[Int(index)].raw
        }
        #expect(keys == expected)
        #expect(indices == [0, 1, 2])
    }

    @Test func emptyCountMakesNoIndexCalls() throws {
        let keys = try SMCBridge.enumeratedKeys(countInfo: countInfo, countBytes: countBytes(0)) { _ in
            Issue.record("An empty enumeration attempted an index read")
            return 0
        }
        #expect(keys.isEmpty)
    }

    @Test func unreasonableCountIsRejectedBeforeReadingIndices() {
        do {
            _ = try SMCBridge.enumeratedKeys(countInfo: countInfo, countBytes: countBytes(65_537)) { _ in
                Issue.record("An invalid count attempted an index read")
                return 0
            }
            Issue.record("An excessive key count was accepted")
        } catch SMCError.invalidKeyCount(let count) {
            #expect(count == 65_537)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func countMustBeACompleteUI32Value() {
        let malformedCounts = [Data(), Data([0, 0, 1]), Data([0, 0, 0, 1, 0])]
        for bytes in malformedCounts {
            #expect(throws: SMCError.self) {
                try SMCBridge.enumeratedKeys(countInfo: countInfo, countBytes: bytes) { _ in
                    Issue.record("A malformed count attempted an index read")
                    return 0
                }
            }
        }
        #expect(throws: SMCError.self) {
            try SMCBridge.enumeratedKeys(
                countInfo: SMCKeyInfo(dataSize: 4, dataType: SMCKey("flt ").raw),
                countBytes: countBytes(1),
            ) { _ in
                Issue.record("A non-ui32 count attempted an index read")
                return 0
            }
        }
    }

    @Test func invalidOrDuplicateIndexRepliesAreRejected() {
        for invalidRaw in [UInt32(0), 0x5400_3035, 0xFF70_3035] {
            #expect(throws: SMCError.self) {
                try SMCBridge.enumeratedKeys(countInfo: countInfo, countBytes: countBytes(1)) { _ in
                    invalidRaw
                }
            }
        }
        #expect(throws: SMCError.self) {
            try SMCBridge.enumeratedKeys(countInfo: countInfo, countBytes: countBytes(2)) { _ in
                SMCKey("Tp05").raw
            }
        }
    }

    @Test func indexReadFailuresPropagate() {
        enum ReadFailure: Error { case unavailable }
        #expect(throws: ReadFailure.self) {
            try SMCBridge.enumeratedKeys(countInfo: countInfo, countBytes: countBytes(1)) { _ in
                throw ReadFailure.unavailable
            }
        }
    }
}
