import SwiftUI

struct AppUpdateSettings: View {
    @State private var updater = AppUpdateController.shared

    var body: some View {
        VStack(spacing: 8) {
            if updater.isHomebrewManaged {
                Text("Installed with Homebrew. Update with:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("brew upgrade crafcat7/cellar/peakmon")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if updater.isDevelopmentBuild {
                Text("Updates are disabled in development builds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if let version = updater.availableVersion {
                    Text("Version \(version) is available")
                        .font(.caption)
                        .foregroundStyle(.purple)
                }
                Button("Check for Updates…", systemImage: "arrow.triangle.2.circlepath") {
                    updater.checkForUpdates()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!updater.canCheckForUpdates || updater.isCheckingRelease)
                if updater.isCheckingRelease {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Checking for Updates…")
                }

                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.setAutomaticallyChecksForUpdates($0) },
                ))
                .font(.caption)
                .disabled(updater.startupError != nil)

                if let error = updater.startupError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
