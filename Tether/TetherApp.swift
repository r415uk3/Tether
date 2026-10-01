import SwiftUI
import MTPKit
import TetherCore

@main
struct TetherApp: App {
    @State private var model = AppModel(service: TetherApp.makeService())

    var body: some Scene {
        Window("Tether", id: "main") {
            ContentView()
                .environment(model)
                .task { await model.start() }
                .frame(minWidth: 720, minHeight: 420)
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
