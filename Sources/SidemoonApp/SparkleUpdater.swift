import Foundation
import Sparkle
import SidemoonCompanion

/// Sparkle's standard updater: checks the appcast, shows its own update window, installs and relaunches.
@MainActor
final class SparkleUpdater: Updater {
    private let controller: SPUStandardUpdaterController

    /// Nil while there is no public key to verify updates with, and outside an app bundle; the updater
    /// is then never created, so it never starts.
    init?() {
        guard CompanionConstants.Updates.isConfigured,
              Bundle.main.bundleURL.pathExtension == CompanionConstants.App.bundleExtension else { return nil }
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        controller.startUpdater()
    }

    var automaticallyChecks: Bool { controller.updater.automaticallyChecksForUpdates }
    func setAutomaticallyChecks(_ on: Bool) { controller.updater.automaticallyChecksForUpdates = on }
    func checkForUpdates() { controller.checkForUpdates(nil) }
}
