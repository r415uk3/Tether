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
                        HStack {
                            Label(device.displayName, systemImage: "smartphone")
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                            Spacer()
                            EjectButton(device: device)
                        }
                        ForEach(model.devices.storages[device.id] ?? []) { storage in
                            StorageRow(storage: storage)
                                .tag(StorageSelection(deviceID: device.id, storageID: storage.id))
                        }
                    case .unavailable(let error):
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Label(device.displayName, systemImage: "smartphone")
                                    .accessibilityAddTraits(.isHeader)
                                Spacer()
                                EjectButton(device: device)
                            }
                            Text(error.localizedDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if error == .claimedByOtherProcess {
                                ReleaseButton(deviceID: device.id, name: device.displayName)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("sidebar")
        .navigationSplitViewColumnWidth(min: 190, ideal: 230)
    }
}

private struct EjectButton: View {
    @Environment(AppModel.self) private var model
    let device: DeviceInfo
    @State private var confirming = false
    @State private var pendingCount = 0

    var body: some View {
        Button {
            let count = model.activeTransferCount(for: device.id)
            if count > 0 { pendingCount = count; confirming = true } else { eject() }
        } label: {
            Image(systemName: "eject")
        }
        .buttonStyle(.borderless)
        .help(String(localized: "Eject \(device.displayName)"))
        .accessibilityLabel(String(localized: "Eject \(device.displayName)"))
        .disabled(model.devices.ejecting.contains(device.id))
        .ejectConfirmation(for: device, transferCount: pendingCount, isPresented: $confirming)
    }

    private func eject() { Task { _ = await model.eject(device.id) } }
}

extension View {
    /// Asks before ejecting a phone that still has transfers running; shared by the sidebar and the browser.
    /// `transferCount` is the count when the dialog was requested, so the message doesn't change underneath it.
    func ejectConfirmation(for device: DeviceInfo, transferCount: Int, isPresented: Binding<Bool>) -> some View {
        modifier(EjectConfirmation(device: device, transferCount: transferCount, isPresented: isPresented))
    }
}

private struct EjectConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    let device: DeviceInfo
    let transferCount: Int
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.confirmationDialog(String(localized: "Eject “\(device.displayName)”?"), isPresented: $isPresented) {
            Button("Eject", role: .destructive) { Task { _ = await model.eject(device.id) } }
        } message: {
            Text("\(transferCount) transfers will stop.")
        }
    }
}

private struct ReleaseButton: View {
    @Environment(AppModel.self) private var model
    let deviceID: DeviceID
    let name: String

    var body: some View {
        Button("Release") { Task { _ = await model.devices.release(deviceID) } }
            .controlSize(.small)
            .disabled(model.devices.releasing.contains(deviceID))
            .accessibilityLabel(String(localized: "Release \(name)"))
        if model.devices.releaseErrors[deviceID] != nil {
            Text("Still held. Quit Image Capture and Photos.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AccessibilityText.storage(storage))
    }
}
