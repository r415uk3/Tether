import SwiftUI
import MTPKit
import TetherCore

struct StorageSelection: Hashable {
    let deviceID: DeviceID
    let storageID: UInt32
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    let autoOpen: AutoOpenController?
    @State private var selection: StorageSelection?
    /// A phone that arrived while auto-open is on; selected once its storages load.
    @State private var pendingDevice: DeviceID?

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
        .onChange(of: model.devices.devices) { old, new in
            if autoOpen?.isOn == true,
               let arrived = new.first(where: { device in !old.contains { $0.id == device.id } }) {
                pendingDevice = arrived.id
            }
            if let pendingDevice, !new.contains(where: { $0.id == pendingDevice }) {
                self.pendingDevice = nil // it left before its storages loaded
            }
            ensureSelection()
        }
        .toolbar {
            ToolbarItem(placement: .automatic) { TransfersButton() }
        }
    }

    private func ensureSelection() {
        if let pendingDevice, let storage = model.devices.storages[pendingDevice]?.first {
            selection = StorageSelection(deviceID: pendingDevice, storageID: storage.id)
            self.pendingDevice = nil
            return
        }
        let available = model.devices.devices.flatMap { device in
            (model.devices.storages[device.id] ?? []).map { StorageSelection(deviceID: device.id, storageID: $0.id) }
        }
        if let selection, available.contains(selection) { return }
        selection = available.first
    }
}
