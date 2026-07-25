//
//  AppSurfacePreferences.swift
//  Peakmon
//
//  Shared preference keys for the app's menu-bar and popover surfaces.
//

import Foundation

enum AppSurfacePreferences {
    static let menuBarEnabledKey = "menuBarEnabled"
    static let popoverEnabledKey = "popoverEnabled"

    static var menuBarEnabled: Bool {
        storedBool(forKey: menuBarEnabledKey, defaultValue: true)
    }

    static var popoverEnabled: Bool {
        storedBool(forKey: popoverEnabledKey, defaultValue: true)
    }

    static var popoverAvailable: Bool {
        menuBarEnabled && popoverEnabled
    }

    private static func storedBool(forKey key: String, defaultValue: Bool) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}
