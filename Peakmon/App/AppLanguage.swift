//
//  AppLanguage.swift
//  Peakmon
//
//  User-selectable display language. Peakmon intentionally defaults to
//  English instead of inheriting the host's locale so a first launch has a
//  stable presentation across machines.
//

import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let storageKey = "appLanguage"
    static let `default`: Self = .english

    var id: String { rawValue }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    var displayName: LocalizedStringKey {
        switch self {
        case .english:
            "English"
        case .simplifiedChinese:
            "Simplified Chinese"
        }
    }

    static var current: Self {
        guard let rawValue = UserDefaults.standard.string(forKey: storageKey),
              let language = Self(rawValue: rawValue)
        else {
            return .default
        }
        return language
    }

    /// Resolves a string for AppKit surfaces that do not inherit SwiftUI's
    /// `Locale` environment, such as status-item tooltips and notifications.
    func localizedString(for key: String) -> String {
        guard let path = Bundle.main.path(forResource: rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else {
            return key
        }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
}
