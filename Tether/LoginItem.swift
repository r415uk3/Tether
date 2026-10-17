import AppKit
import ServiceManagement
import TetherCore

/// The embedded `TetherLauncher` login item, registered through `SMAppService`.
@MainActor
final class SMLoginItem: LoginItemService {
    static let launcherBundleID = "dev.tether.Tether.Launcher"

    private let service = SMAppService.loginItem(identifier: SMLoginItem.launcherBundleID)

    var status: LoginItemStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }

    static func isLauncherRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: launcherBundleID).isEmpty
    }
}
