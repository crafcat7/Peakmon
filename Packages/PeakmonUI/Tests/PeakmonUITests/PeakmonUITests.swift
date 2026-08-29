@testable import PeakmonUI
import SwiftUI
import Testing

@Suite("PeakmonUI")
@MainActor
struct PeakmonUITests {
    @Test func colorHexRoundTripsOpaqueRGB() {
        #expect(Color(hex: "#007AFF")?.hexString == "#007AFF")
    }

    @Test func menuBarPercentFormattingHandlesTwoAndThreeDigitBoundaries() {
        #expect(MenuBarPercentFormatting.string(for: 9) == "9%")
        #expect(MenuBarPercentFormatting.string(for: 10) == "10%")
        #expect(MenuBarPercentFormatting.string(for: 99) == "99%")
        #expect(MenuBarPercentFormatting.string(for: 100) == "100%")
        #expect(MenuBarPercentFormatting.string(for: 999) == "999%")
    }

    @Test func menuBarPercentFormattingRoundsAtDisplayBoundary() {
        #expect(MenuBarPercentFormatting.string(for: 99.49) == "99%")
        #expect(MenuBarPercentFormatting.string(for: 99.5) == "100%")
        #expect(MenuBarPercentFormatting.string(for: 100.49) == "100%")
        #expect(MenuBarPercentFormatting.string(for: 100.5) == "101%")
    }

    @Test func menuBarPercentValueWidthFitsTwoAndThreeDigitValues() {
        let font = Font.system(size: 11, weight: .medium).monospacedDigit()
        let values = [9.0, 10.0, 99.0, 100.0, 999.0]

        for scale in [CGFloat(1), CGFloat(2)] {
            let widths = values.compactMap { value in
                let renderer = ImageRenderer(
                    content: MenuBarPercentValue(
                        text: MenuBarPercentFormatting.string(for: value),
                    )
                    .font(font),
                )
                renderer.scale = scale
                return renderer.nsImage?.size.width
            }
            let naturalRenderer = ImageRenderer(
                content: Text(MenuBarPercentValue.referenceText)
                    .font(font)
                    .fixedSize(horizontal: true, vertical: false),
            )
            naturalRenderer.scale = scale
            let naturalWidth = naturalRenderer.nsImage?.size.width

            #expect(widths.count == values.count)
            guard widths.count == values.count else { return }
            let referenceWidth = widths[3]
            #expect(widths.allSatisfy { abs($0 - referenceWidth) < 0.01 })
            #expect(naturalWidth.map { abs($0 - referenceWidth) < 0.01 } == true)
        }

        // The hidden three-digit reference reserves the full 100% width for
        // every value at both backing scales, so 9 -> 99 -> 100 cannot
        // reflow the status item or truncate the visible text.
        #expect(MenuBarPercentValue.referenceText == "100%")
    }
}
