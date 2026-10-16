import AppKit
import os

/// Opens the Tether app this login item is embedded in.
@MainActor
final class TetherOpener {
    private let logger = Logger(subsystem: "dev.tether.Tether.Launcher", category: "opener")

    func open() {
        // TetherLauncher.app → LoginItems → Library → Contents → Tether.app
        var appURL = Bundle.main.bundleURL
        for _ in 0..<4 { appURL.deleteLastPathComponent() }
        guard appURL.pathExtension == "app" else {
            logger.error("Not embedded in an app bundle (\(appURL.path, privacy: .public)); not opening Tether")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { [logger] _, error in
            if let error {
                logger.error("Opening Tether failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
