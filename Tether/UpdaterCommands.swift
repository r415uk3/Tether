import SwiftUI
import Sparkle

/// Owns Sparkle's updater for the app's lifetime.
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate {
    private(set) var controller: SPUStandardUpdaterController!
    /// Whether Sparkle's updater was actually started (false for fake devices or the placeholder key).
    let isStarted: Bool

    /// `start: false` (UI tests, demos) keeps the updater idle so nothing touches the network.
    init(start: Bool) {
        isStarted = start
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: self, userDriverDelegate: nil)
    }

    var updater: SPUUpdater { controller.updater }

    /// True only when the bundle carries a real Ed25519 public key (32 bytes, base64). With the build placeholder the
    /// updater is never started, so Sparkle never shows "Unable to Check For Updates".
    static var isConfigured: Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let data = Data(base64Encoded: key) else { return false }
        return data.count == 32
    }

    /// Whether Sparkle's updater was actually started.

    /// `-TetherFeedURL <url>` points at a test feed (local update testing only).
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        guard let raw = UserDefaults.standard.string(forKey: "TetherFeedURL"),
              let host = URL(string: raw)?.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost" else { return nil }
        return raw
    }
}

struct UpdaterCommands: Commands {
    let updater: Updater
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.controller.checkForUpdates(nil) }
                .disabled(!updater.isStarted)
        }
    }
}
