//
//  MainWindowTopBar.swift
//  Peakmon
//
//  Floating pill segmented control that lives at the top of the
//  unified main window scene and switches between
//  `MainWindowTab.dashboard` and `MainWindowTab.settings`.
//
//  Visual model (reference: the third-party monitor.app screenshot
//  the user pinned during the 2026-05-26 D1 redesign):
//
//    ┌──────────────────────────────────────────────────────────┐
//    │   ╭───────── Dashboard ──╮  ──── Settings  ────╮         │
//    │   ╰──────────────────────╯                     ╯         │
//    └──────────────────────────────────────────────────────────┘
//
//  - Outer container: thick rounded capsule (`Capsule(style:
//    .continuous)`) filled with a thin `.regularMaterial` so it
//    reads as a floating chip atop whichever detail surface is
//    underneath. Light 1pt border for definition.
//  - Inner indicator: another `Capsule` matched-geometry-id'd
//    across the two tabs so switching slides the highlight rather
//    than fading it. Filled with `.accentColor` so the user's
//    system accent flows through (one of the v1.3 design rules:
//    don't lock a brand palette, follow the user).
//  - Labels: `Label(title, systemImage:)` with `.iconOnly` is
//    deliberately NOT used — both icon and text show, because the
//    pill is the primary navigation affordance and needs to be
//    self-explanatory at first glance.
//
//  Why a separate file: keeping the chrome in its own view makes
//  the future v1.4 work (e.g. injecting a "Live" indicator chip
//  on the right side of the toolbar, or a window-size disclosure
//  button) a localised edit instead of touching `MainWindowView`.
//

import SwiftUI

struct MainWindowTopBar: View {
    @Binding var selection: MainWindowTab

    /// Matched-geometry namespace used to slide the accent capsule
    /// between tabs. Declared on this view (not the parent) because
    /// the parent doesn't otherwise need to know about the pill's
    /// internal animation; if a future iteration needs to coordinate
    /// the pill with toolbar trailing content, this can be lifted.
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
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        // Accessibility: expose the pill as a single tab bar so
        // VoiceOver users hear "Tab bar, 2 items" rather than two
        // unrelated buttons.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Main navigation")
    }

    @ViewBuilder
    private func tabButton(_ tab: MainWindowTab) -> some View {
        let isSelected = selection == tab

        Button {
            // `.spring(response: 0.35, dampingFraction: 0.85)` was
            // chosen empirically — a faster spring (0.25) felt
            // jittery, the SwiftUI default (~0.55) felt sluggish
            // for a chrome-level interaction that the user expects
            // to be near-instant.
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
                        .shadow(color: .accentColor.opacity(0.35), radius: 4, y: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#Preview {
    struct PreviewHost: View {
        @State private var selection: MainWindowTab = .dashboard
        var body: some View {
            VStack {
                MainWindowTopBar(selection: $selection)
                Text("Selected: \(selection.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 24)
            }
            .padding(40)
            .frame(width: 600, height: 200)
        }
    }
    return PreviewHost()
}
