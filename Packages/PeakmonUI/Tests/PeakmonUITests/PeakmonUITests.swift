@testable import PeakmonUI
import Testing

@Suite("PeakmonUI scaffolding")
struct PeakmonUITests {
    @Test func versionMarkerIsSet() {
        #expect(PeakmonUI.versionMarker == "v0.0-scaffold")
    }
}
