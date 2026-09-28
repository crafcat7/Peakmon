import Foundation

/// Homebrew owns the resolved Cellar bundle, including /Applications symlinks.
enum AppUpdateInstallation {
    static func isHomebrewManaged(_ bundleURL: URL) -> Bool {
        let components = bundleURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return components.indices.contains { index in
            components[index] == "Cellar"
                && index + 3 < components.count
                && components[index + 1] == "peakmon"
                && components[index + 3] == "Peakmon.app"
        }
    }
}
