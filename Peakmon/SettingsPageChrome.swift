//
//  SettingsPageChrome.swift
//  Peakmon
//
//  Reusable building blocks for the Settings detail views: a page
//  scaffold with a tinted glyph header, a labelled section card, and
//  the "Coming soon" pill used to mark deferred features.
//

import SwiftUI

// MARK: - Page

struct SettingsPage<Content: View>: View {
    let category: SettingsCategory
    let subtitle: String?
    let content: Content

    init(
        _ category: SettingsCategory,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content,
    ) {
        self.category = category
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(category.tint.gradient)
                        Image(systemName: category.systemImage)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 36, height: 36)
                    .shadow(color: category.tint.opacity(0.35), radius: 6, y: 2)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.title)
                            .font(.title2.weight(.semibold))
                        if let subtitle {
                            Text(subtitle)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Section

struct SettingsSection<Content: View>: View {
    let title: String
    let footer: String?
    let systemImage: String?
    let iconTint: Color?
    let content: Content

    init(
        _ title: String,
        systemImage: String? = nil,
        iconTint: Color? = nil,
        footer: String? = nil,
        @ViewBuilder content: () -> Content,
    ) {
        self.title = title
        self.footer = footer
        self.systemImage = systemImage
        self.iconTint = iconTint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(iconTint ?? .secondary)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            content
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: .rect(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.gray.opacity(0.18), lineWidth: 0.5)
                }
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Coming soon badge

struct ComingSoonBadge: View {
    var body: some View {
        Text("Coming soon")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.gray.opacity(0.18), in: .capsule)
    }
}
