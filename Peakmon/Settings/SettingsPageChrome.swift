//
//  SettingsPageChrome.swift
//  Peakmon
//
//  Reusable building blocks for the Settings detail views: a page
//  scaffold with a tinted glyph header, a labelled section card, and
//  the "Coming soon" pill used to mark deferred features.
//

import PeakmonUI
import SwiftUI

// MARK: - Page

struct SettingsPage<Content: View>: View {
    let content: Content

    init(
        @ViewBuilder content: () -> Content,
    ) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

/// A single, regular overview row for the compact General settings.
/// Keeping the three cards in one row avoids the staggered masonry gaps
/// produced by two independent vertical columns.
struct SettingsOverviewRow<Primary: View, Secondary: View, Tertiary: View>: View {
    let primary: Primary
    let secondary: Secondary
    let tertiary: Tertiary

    init(
        @ViewBuilder primary: () -> Primary,
        @ViewBuilder secondary: () -> Secondary,
        @ViewBuilder tertiary: () -> Tertiary,
    ) {
        self.primary = primary()
        self.secondary = secondary()
        self.tertiary = tertiary()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                primary
                    .frame(minWidth: 300, maxWidth: .infinity, alignment: .top)
                secondary
                    .frame(minWidth: 300, maxWidth: .infinity, alignment: .top)
                tertiary
                    .frame(minWidth: 260, maxWidth: .infinity, alignment: .top)
            }

            VStack(spacing: 16) {
                primary
                secondary
                tertiary
            }
        }
    }
}

// MARK: - Responsive groups

/// Lets Settings use two columns at the normal main-window width and
/// naturally fall back to one column when the window is narrowed.
struct SettingsAdaptiveGrid<Content: View>: View {
    let minimumColumnWidth: CGFloat
    let content: Content

    init(
        minimumColumnWidth: CGFloat = 340,
        @ViewBuilder content: () -> Content,
    ) {
        self.minimumColumnWidth = minimumColumnWidth
        self.content = content()
    }

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: minimumColumnWidth), spacing: 16, alignment: .top)],
            alignment: .leading,
            spacing: 16,
        ) {
            content
        }
    }
}

/// Compact per-card inspector used by Display settings. Visibility is
/// promoted to the tile header so the body can focus on appearance and
/// series configuration without repeating "Show in dashboard" eight times.
struct SettingsCardTile<Content: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    @Binding var isOn: Bool
    let content: Content

    init(
        title: String,
        systemImage: String,
        tint: Color,
        isOn: Binding<Bool>,
        @ViewBuilder content: () -> Content,
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        _isOn = isOn
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(0.13), in: .rect(cornerRadius: 6))

                Text(LocalizedStringKey(title))
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Toggle("Show \(title)", isOn: $isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }

            Divider().opacity(0.55)

            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .peakmonGlassSurface(
            tint: tint,
            cornerRadius: 10,
            tintOpacity: isOn ? 0.09 : 0.04,
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isOn ? tint.opacity(0.18) : Color.gray.opacity(0.14), lineWidth: 0.5)
        }
        .opacity(isOn ? 1 : 0.72)
        .animation(.easeOut(duration: 0.18), value: isOn)
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(iconTint ?? .secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            (iconTint ?? .secondary).opacity(0.11),
                            in: .rect(cornerRadius: 6),
                        )
                }
                Text(LocalizedStringKey(title))
                    .font(.caption.weight(.semibold))

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().opacity(0.5)

            content
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let footer {
                Text(LocalizedStringKey(footer))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .peakmonGlassSurface(
            tint: iconTint,
            cornerRadius: 11,
            tintOpacity: 0.08,
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke((iconTint ?? .gray).opacity(0.16), lineWidth: 0.5)
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
