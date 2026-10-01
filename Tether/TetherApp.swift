import SwiftUI
import MTPKit
import TetherCore

@main
struct TetherApp: App {
    /// `-CacheDirectory <path>` (UI tests) keeps thumbnails and previews out of the real Caches folder.
    private static let cacheRoot: URL? = UserDefaults.standard.string(forKey: "CacheDirectory").map(URL.init(fileURLWithPath:))
    private static var previewDirectory: URL {
        cacheRoot?.appending(path: "Previews") ?? PreviewCache.defaultDirectory
    }

    @State private var model = AppModel(service: TetherApp.makeService(),
                                        thumbnailDirectory: TetherApp.cacheRoot?.appending(path: "Thumbnails")
                                            ?? ThumbnailStore.defaultDirectory,
                                        previewDirectory: TetherApp.previewDirectory)

    init() {
        let previews = Self.previewDirectory
        PreviewCache.clear(directory: previews) // willTerminate doesn't fire after a crash or force-quit
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { _ in
            PreviewCache.clear(directory: previews)
        }
    }

    var body: some Scene {
        Window("Tether", id: "main") {
            ContentView()
                .environment(model)
                .task { await model.start() }
                .frame(minWidth: 720, minHeight: 420)
        }
        .commands {
            BrowserCommands()
            DiagnosticsCommands(model: model)
        }

        Settings {
            SettingsView()
        }
    }

    /// `-UseFakeDevices YES` swaps the XPC helper for in-memory demo phones.
    private static func makeService() -> any MTPService {
        if UserDefaults.standard.bool(forKey: "UseFakeDevices") {
            return LocalMTPService(provider: FakeDeviceProvider.demo())
        }
        return XPCMTPService.helper()
    }
}
