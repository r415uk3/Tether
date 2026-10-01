import SwiftUI
import MTPKit
import TetherCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: StorageSelection?

    var body: some View {
        List(selection: $selection) {
            Section("Devices") {
                ForEach(model.devices.devices) { device in
                    switch device.state {
                    case .ready:
                        Label(device.displayName, systemImage: "smartphone")
                            .font(.headline)
                        ForEach(model.devices.storages[device.id] ?? []) { storage in
                            StorageRow(storage: storage)
                                .tag(StorageSelection(deviceID: device.id, storageID: storage.id))
                        }
                    case .unavailable(let error):
                        VStack(alignment: .leading, spacing: 2) {
                            Label(device.displayName, systemImage: "smartphone")
                            Text(error.localizedDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if error == .claimedByOtherProcess {
                                ReleaseButton(deviceID: device.id)
                            }
                        }
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 230)
    }
}

private struct ReleaseButton: View {
    @Environment(AppModel.self) private var model
    let deviceID: DeviceID
    @State private var releasing = false

    var body: some View {
        Button("Release") {
            guard !releasing else { return }
            releasing = true
            Task {
                _ = await model.devices.release(deviceID) // the detail view reports a failure
                releasing = false
            }
        }
        .controlSize(.small)
        .disabled(releasing)
    }
}

private struct StorageRow: View {
    let storage: StorageInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(storage.name, systemImage: "internaldrive")
            if storage.capacity > 0 {
                ProgressView(value: Double(storage.capacity - min(storage.freeSpace, storage.capacity)),
                             total: Double(storage.capacity))
                    .controlSize(.mini)
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(clamping: storage.freeSpace), countStyle: .file)) available")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 12)
    }
}
