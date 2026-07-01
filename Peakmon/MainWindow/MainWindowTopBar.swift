//
//  MainWindowTopBar.swift
//  Peakmon
//
//  Floating pill segmented control at the top of the unified main
//  window; switches Dashboard / History / Settings.
//
//  Visual model:
//  - Outer: continuous `Capsule` filled `.regularMaterial` with a
//    1pt border, reading as a floating chip over the detail surface.
//  - Indicator: an accent-filled `Capsule`, matched-geometry'd across
//    tabs so selection slides rather than fades. Accent follows the
//    user's system tint (v1.3 rule: don't lock a brand palette).
//  - Labels show both icon and text — the pill is the primary nav
//    affordance and must be self-explanatory.
//
//  Separate file so future toolbar additions (e.g. a "Live" chip)
//  stay localised rather than touching `MainWindowView`.
//

import SwiftUI

struct MainWindowTopBar: View {
    @Binding var selection: MainWindowTab

    /// Matched-geometry namespace that slides the accent capsule
    /// between tabs. Declared here since the parent doesn't need the
    /// pill's internal animation.
    @Namespace private var pillNamespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MainWindowTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(4)
        .background(
            Capsule(style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        // A drop shadow used to sit here, but SwiftUI rebuilt its
        // blur source layer every scroll frame (`apply_blur` →
        // `vImageSepConvolve_ARGB8888` in `sample`). The border +
        // material already separate the pill from the surface.
        // Accessibility: expose as one tab bar ("Tab bar, 3 items")
        // rather than two unrelated buttons.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Main navigation")
    }

    @ViewBuilder
    private func tabButton(_ tab: MainWindowTab) -> some View {
        let isSelected = selection == tab

        Button {
            // Spring tuned empirically: faster (0.25) felt jittery,
            // the SwiftUI default (~0.55) felt sluggish for chrome.
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                selection = tab
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(tab.title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.7))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(Color.accentColor)
                        .matchedGeometryEffect(id: "pill", in: pillNamespace)
                    // Selected-tab accent glow removed for the same
                    // reason as the pill shadow — a blurred source
                    // layer rebuilt every scroll commit. The accent
                    // fill alone carries the selection affordance.
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
