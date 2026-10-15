import Foundation
import Sparkle

/// Sparkle is enabled only in signed public builds. Local source builds keep
/// the framework linked so they exercise the same packaging, but do not fetch
/// a public feed or offer an update that cannot replace an ad-hoc app.
@MainActor
final class UpdateService {
    private var controller: SPUStandardUpdaterController?

    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    func start() {
        guard controller == nil,
              Bundle.main.object(forInfoDictionaryKey: "SparkBarUpdatesEnabled") as? Bool == true,
              Bundle.main.bundleURL.pathExtension == "app",
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              URL(string: feed)?.scheme == "https",
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.isEmpty else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }
}
