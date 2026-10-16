import SwiftUI
import MTPKit
import TetherCore

@main
struct TetherApp: App {
    /// `-CacheDirectory <path>` (UI tests) keeps thumbnails and previews out of the real Caches folder.
    private static let cacheRoot: URL? = UserDefaults.standard.string(forKey: "CacheDirectory")
        .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil } // empty or relative values fall back to the defaults
    private static var previewDirectory: URL {
        cacheRoot?.appending(path: "Previews") ?? PreviewCache.defaultDirectory
    }

    @State private var model = AppModel(service: TetherApp.makeService(),
                                        thumbnailDirectory: TetherApp.cacheRoot?.appending(path: "Thumbnails")
                                            ?? ThumbnailStore.defaultDirectory,
                                        previewDirectory: TetherApp.previewDirectory)

    private let updater = Updater(start: !UserDefaults.standard.bool(forKey: "UseFakeDevices") && Updater.isConfigured)

    /// `nil` in fake mode, so UI tests never touch the real login item. Static, so there is one per launch.
    private static let autoOpenController: AutoOpenController? = makeAutoOpen()
    private var autoOpen: AutoOpenController? { Self.autoOpenController }

    init() {
        let previews = Self.previewDirectory
        PreviewCache.clear(directory: previews) // willTerminate doesn't fire after a crash or force-quit
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { _ in
            PreviewCache.clear(directory: previews)
        }
        // Once per launch, independent of the window and of the first device load.
        // No-op unless an update left the launcher stale.
        Self.autoOpenController?.repairOncePerLaunch()
    }

    var body: some Scene {
        Window("Tether", id: "main") {
            ContentView(autoOpen: autoOpen)
                .environment(model)
                .task { await model.start() }
                .frame(minWidth: 720, minHeight: 420)
        }
        .commands {
            BrowserCommands()
            DiagnosticsCommands(model: model)
            UpdaterCommands(updater: updater)
        }

        Settings {
            SettingsView(updater: updater, autoOpen: autoOpen)
        }
    }

    /// `-UseFakeDevices YES` swaps the XPC helper for in-memory demo phones.
    private static func makeService() -> any MTPService {
        if UserDefaults.standard.bool(forKey: "UseFakeDevices") {
            return LocalMTPService(provider: FakeDeviceProvider.demo())
        }
        return XPCMTPService.helper()
    }

    private static func makeAutoOpen() -> AutoOpenController? {
        guard !UserDefaults.standard.bool(forKey: "UseFakeDevices") else { return nil }
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return AutoOpenController(service: SMLoginItem(), currentVersion: "\(short) (\(build))",
                                  isHelperRunning: SMLoginItem.isLauncherRunning)
    }
}
