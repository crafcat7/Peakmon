import AppKit
import Observation
import OSLog
import Sparkle

/// App-level updater; Sparkle owns scheduling, validation, installation and restart.
@MainActor
@Observable
final class AppUpdateController: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = AppUpdateController()

    let isHomebrewManaged = AppUpdateInstallation.isHomebrewManaged(Bundle.main.bundleURL)
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = false
    private(set) var availableVersion: String?
    private(set) var startupError: String?
    private(set) var isCheckingRelease = false

    #if DEBUG
        let isDevelopmentBuild = true
    #else
        let isDevelopmentBuild = false
    #endif

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private let logger = Logger(subsystem: "com.crafcat7.Peakmon", category: "updates")

    func start() {
        guard controller == nil, !isHomebrewManaged, !isDevelopmentBuild else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self,
        )
        self.controller = controller
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? false
                Task { @MainActor in self?.canCheckForUpdates = value }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, change in
                let value = change.newValue ?? false
                Task { @MainActor in self?.automaticallyChecksForUpdates = value }
            },
        ]
        do {
            try updater.start()
        } catch {
            startupError = error.localizedDescription
            logger.error("Unable to start updater: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        guard canCheckForUpdates, !isCheckingRelease else { return }
        isCheckingRelease = true
        Task { @MainActor in
            defer { isCheckingRelease = false }
            do {
                let release = try await GitHubReleaseChecker.latest()
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
                if try !release.isNewer(than: version, build: build) {
                    availableVersion = nil
                    showReleaseAlert(title: "You're up to date", message: "No newer release is available. Current version: %@.", version: version)
                } else if release.hasUpdateFeed {
                    ActivationPolicyController.shared.setUpdateSessionActive(true)
                    NSApp.activate(ignoringOtherApps: true)
                    controller?.checkForUpdates(nil)
                } else {
                    availableVersion = try release.version().displayString
                    showReleaseAlert(
                        title: "Update available",
                        message: "Peakmon %@ is available. Open its release page to download the update.",
                        version: availableVersion ?? "",
                        releaseURL: release.htmlURL,
                    )
                }
            } catch {
                logger.info("GitHub release check failed: \(error.localizedDescription, privacy: .public)")
                showReleaseAlert(title: "Unable to check for updates", message: "Could not retrieve the latest release from GitHub. Please try again later.")
            }
        }
    }

    private func showReleaseAlert(title: String, message: String, version: String? = nil, releaseURL: URL? = nil) {
        ActivationPolicyController.shared.setUpdateSessionActive(true)
        NSApp.activate(ignoringOtherApps: true)
        defer { ActivationPolicyController.shared.setUpdateSessionActive(false) }
        let language = AppLanguage.current
        let alert = NSAlert()
        alert.messageText = language.localizedString(for: title)
        let format = language.localizedString(for: message)
        alert.informativeText = version.map { String(format: format, $0) } ?? format
        alert.addButton(withTitle: language.localizedString(for: releaseURL == nil ? "OK" : "View Release"))
        if releaseURL != nil { alert.addButton(withTitle: language.localizedString(for: "Later")) }
        if alert.runModal() == .alertFirstButtonReturn, let releaseURL {
            NSWorkspace.shared.open(releaseURL)
        }
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool,
    ) -> Bool {
        // Background checks leave a reminder in Settings rather than stealing focus.
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState,
    ) {
        availableVersion = update.displayVersionString
        if handleShowingUpdate {
            ActivationPolicyController.shared.setUpdateSessionActive(true)
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
        ActivationPolicyController.shared.setUpdateSessionActive(false)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error {
            logger.info("Update cycle finished: \(error.localizedDescription, privacy: .public)")
        }
        ActivationPolicyController.shared.setUpdateSessionActive(false)
    }
}
