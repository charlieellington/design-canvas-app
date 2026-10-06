// Sparkle auto-update integration — wraps SPUStandardUpdaterController for SwiftUI.
// Provides "Check for Updates" menu action and automatic update checks on launch.
// Requires Sparkle 2.x SPM package to be added to the project.

#if canImport(Sparkle)
import Foundation
import Sparkle

@MainActor
final class UpdaterManager: ObservableObject {
    private var updaterController: SPUStandardUpdaterController?

    @Published var canCheckForUpdates = false

    init() {
        guard BuildPolicy.isOfficialDistribution else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        controller.updater.automaticallyChecksForUpdates = true
        updaterController = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)

        // Check for updates shortly after launch so users are notified promptly,
        // even if the scheduled interval hasn't elapsed yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.updaterController?.updater.canCheckForUpdates == true else { return }
            self.updaterController?.updater.checkForUpdatesInBackground()
        }
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
}
#else
// Stub when Sparkle is not yet added — allows the app to compile without the dependency.
import Foundation
import AppKit

@MainActor
final class UpdaterManager: ObservableObject {
    @Published var canCheckForUpdates = false

    func checkForUpdates() {
        guard BuildPolicy.isOfficialDistribution else { return }
        // Sparkle not available — open releases page as fallback
        if let url = URL(string: "https://github.com/charlieellington/design-canvas-app") {
            NSWorkspace.shared.open(url)
        }
    }
}
#endif
