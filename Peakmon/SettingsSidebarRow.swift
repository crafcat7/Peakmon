//
//  SettingsSidebarRow.swift
//  Peakmon
//
//  Custom sidebar row used in the Settings window. The row is a plain
//  button so we control hover, selection background and corner radius
//  ourselves instead of inheriting the system sidebar's pill shape.
//

import SwiftUI

struct SettingsSidebarRow: View {
    let category: SettingsCategory
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var background: Color {
        if isSelected {
            return Color.accentColor
        }
        if isHovering {
            return Color.primary.opacity(0.08)
        }
        return .clear
    }

    private var textColor: Color {
        isSelected ? .white : .primary
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(category.tint.gradient)
                    Image(systemName: category.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 22, height: 22)

                Text(category.title)
                    .font(.body)
                    .foregroundStyle(textColor)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: .rect(cornerRadius: 6, style: .continuous))
            .contentShape(.rect(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isSelected)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }
}
