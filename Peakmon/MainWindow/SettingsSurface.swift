//
//  SettingsSurface.swift
//  Peakmon
//
//  Detail surface rendered when the top pill is on
//  `MainWindowTab.settings`. Hosts a smaller sub-pill segmented
//  control along the top of the surface that switches between the
//  three `SettingsCategory` pages (General / Display / About).
//
//  Design rationale:
//    • The user picked "keep three pages, embed sub-tab inside the
//      Settings tab" over "merge into one scrolling page" — so the
//      three Page views (`GeneralPage`/`DisplayPage`/`AboutPage`)
//      from `SettingsView.swift` are reused verbatim. Each retains
//      its own `SettingsPage` chrome and `SettingsSection` layout;
//      this file only owns the picker.
//    • The sub-pill is intentionally smaller and lower-contrast
//      than the main `MainWindowTopBar` pill. The hierarchy reads
//      as "you are in Settings → pick a sub-section" rather than
//      two equally-prominent navigation chips.
//    • Sub-pill animation uses the same spring as the top bar
//      (`response: 0.35, dampingFraction: 0.85`) for consistency.
//

import SwiftUI

struct SettingsSurface: View {
    @Binding var selection: SettingsCategory

    @Namespace private var subPillNamespace

    var body: some View {
        VStack(spacing: 0) {
            subPill
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()
                .opacity(0.5)

            // Each Page already wraps itself in a ScrollView via
            // `SettingsPage`/`SettingsPageChrome`, so the surface
            // can hand the full remaining height to the page
            // without adding another scroll container.
            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var subPill: some View {
        HStack(spacing: 4) {
            ForEach(SettingsCategory.allCases) { category in
                subPillButton(category)
            }
        }
        .padding(4)
        .background(
            Capsule(style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings section")
    }

    @ViewBuilder
    private func subPillButton(_ category: SettingsCategory) -> some View {
        let isSelected = selection == category

        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                selection = category
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: category.systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(category.title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(.background)
                        .matchedGeometryEffect(id: "subpill", in: subPillNamespace)
                        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var pageContent: some View {
        // Switching on the enum produces a different concrete view
        // type per case, so wrapping in a Group + `.transition`
        // gives the swap a quick cross-fade rather than the harsh
        // pop SwiftUI defaults to when the view identity changes.
        Group {
            switch selection {
            case .general: GeneralPage()
            case .display: DisplayPage()
            }
        }
        .transition(.opacity.combined(with: .move(edge: .trailing)))
        .id(selection)
    }
}
