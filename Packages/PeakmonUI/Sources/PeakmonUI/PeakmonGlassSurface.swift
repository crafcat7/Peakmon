//
//  PeakmonGlassSurface.swift
//  PeakmonUI
//
//  Shared translucent panel treatment for the main window and popover.
//  macOS 26 uses native Liquid Glass; older supported systems retain the
//  same hierarchy through a tinted thin-material fallback.
//

import SwiftUI

private struct PeakmonGlassSurfaceModifier: ViewModifier {
    let tint: Color?
    let cornerRadius: CGFloat
    let tintOpacity: Double

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(macOS 26.0, *) {
            if let tint {
                content
                    .glassEffect(.clear.tint(tint.opacity(tintOpacity)), in: shape)
            } else {
                content
                    .glassEffect(.clear, in: shape)
            }
        } else {
            content
                .background {
                    shape.fill(.thinMaterial)

                    if let tint {
                        shape.fill(
                            LinearGradient(
                                colors: [tint.opacity(tintOpacity * 0.55), .clear],
                                startPoint: .topLeading,
                                endPoint: .center,
                            ),
                        )
                    }
                }
        }
    }
}

public extension View {
    /// Applies Peakmon's restrained glass panel treatment.
    ///
    /// - Parameters:
    ///   - tint: Optional semantic color for the panel. Omit it for
    ///     neutral containers such as Processes and anomaly lists.
    ///   - cornerRadius: Radius of the glass shape.
    ///   - tintOpacity: Color strength passed to native glass. Keep this
    ///     low for dense data surfaces so text and charts remain dominant.
    func peakmonGlassSurface(
        tint: Color? = nil,
        cornerRadius: CGFloat = 14,
        tintOpacity: Double = 0.12,
    ) -> some View {
        modifier(PeakmonGlassSurfaceModifier(
            tint: tint,
            cornerRadius: cornerRadius,
            tintOpacity: tintOpacity,
        ))
    }
}
