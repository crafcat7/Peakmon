//
//  SettingsSurface.swift
//  Peakmon
//
//  Detail surface for `MainWindowTab.settings`. Hosts a small sub-pill
//  along the top that switches the `SettingsCategory` pages, reusing
//  the existing Page views from `SettingsView.swift` verbatim (each
//  keeps its own `SettingsPage` chrome); this file owns only the picker.
//
//  The sub-pill is deliberately smaller and lower-contrast than the
//  main `MainWindowTopBar` pill so the hierarchy reads as "in Settings
//  → pick a sub-section". It uses the same spring (response 0.35,
//  damping 0.85) as the top bar for consistency.
//

import SwiftUI

struct SettingsSurface: View {
    @Binding var selection: SettingsCategory

    @Namespace private var subPillNamespace

    var body: some View {
        VStack(spacing: 0) {
            settingsHeader

            Divider()
                .opacity(0.5)

            // Each Page wraps itself in a ScrollView via
            // `SettingsPage`, so hand it the full remaining height
            // without another scroll container.
            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var settingsHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: selection.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(selection.tint)
                .frame(width: 32, height: 32)
                .background(selection.tint.opacity(0.13), in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(selection.tint.opacity(0.20), lineWidth: 0.5)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(selection.title)
                    .font(.headline)
                Text(selection.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 20)

            subPill
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: 1120)
        .frame(maxWidth: .infinity)
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
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(category.tint.opacity(0.13))
                        .matchedGeometryEffect(id: "subpill", in: subPillNamespace)
                        .overlay {
                            Capsule(style: .continuous)
                                .stroke(category.tint.opacity(0.18), lineWidth: 0.5)
                        }
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
        // Each case is a distinct concrete view type, so Group +
        // `.transition` cross-fades the swap instead of the harsh pop
        // SwiftUI defaults to on identity change.
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
