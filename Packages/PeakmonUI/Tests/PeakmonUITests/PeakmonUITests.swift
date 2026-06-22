@testable import PeakmonUI
import SwiftUI
import Testing

@Suite("PeakmonUI")
struct PeakmonUITests {
    @Test func colorHexRoundTripsOpaqueRGB() {
        #expect(Color(hex: "#007AFF")?.hexString == "#007AFF")
    }
}
