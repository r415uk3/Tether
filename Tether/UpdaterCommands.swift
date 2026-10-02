import SwiftUI
import Sparkle

/// Owns Sparkle's updater for the app's lifetime.
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate {
    private(set) var controller: SPUStandardUpdaterController!

    /// `start: false` (UI tests, demos) keeps the updater idle so nothing touches the network.
    init(start: Bool) {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: self, userDriverDelegate: nil)
    }

    var updater: SPUUpdater { controller.updater }

    /// `-TetherFeedURL <url>` points at a test feed (local update testing only).
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "TetherFeedURL")
    }
}

struct UpdaterCommands: Commands {
    let updater: Updater
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.controller.checkForUpdates(nil) }
        }
    }
}
