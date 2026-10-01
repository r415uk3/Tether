import SwiftUI
import MTPKit
import TetherCore

struct StorageSelection: Hashable {
    let deviceID: DeviceID
    let storageID: UInt32
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: StorageSelection?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            if let selection {
                BrowserView(selection: selection)
                    .id(selection)
            } else if let device = model.devices.devices.first(where: { $0.state == .ready })
                        ?? model.devices.devices.first {
                DeviceStateView(device: device)
            } else if !model.devices.hasLoaded {
                ProgressView() // avoid flashing the no-phone guide before the first device load finishes
            } else {
                NoPhoneView()
            }
        }
        .onChange(of: selection) {
            if selection == nil { ensureSelection() } // empty-space click deselects; keep a ready storage selected
        }
        .onChange(of: model.devices.storages, initial: true) { ensureSelection() }
        .onChange(of: model.devices.devices) { ensureSelection() }
        .toolbar {
            TetherToolbarSpacer()
            ToolbarItem(placement: .primaryAction) { TransfersButton() }
        }
    }

    private func ensureSelection() {
        let available = model.devices.devices.flatMap { device in
            (model.devices.storages[device.id] ?? []).map { StorageSelection(deviceID: device.id, storageID: $0.id) }
        }
        if let selection, available.contains(selection) { return }
        selection = available.first
    }
}
