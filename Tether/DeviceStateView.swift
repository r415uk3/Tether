import SwiftUI
import MTPKit
import TetherCore

/// Detail view for a phone without a browsable storage: loading, failed, held by another app, or locked.
struct DeviceStateView: View {
    @Environment(AppModel.self) private var model
    let device: DeviceInfo

    var body: some View {
        switch device.state {
        case .ready:
            if let error = model.devices.storageErrors[device.id] {
                ContentUnavailableView {
                    Label("Can’t Read \(device.displayName)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.localizedDescription)
                } actions: {
                    Button("Try Again") { Task { await model.devices.retryStorages(device.id) } }
                }
            } else if let list = model.devices.storages[device.id], list.isEmpty {
                ContentUnavailableView {
                    Label("No Storage Available", systemImage: "internaldrive")
                } description: {
                    Text("Unlock the phone and check that USB is set to File Transfer.")
                } actions: {
                    Button("Try Again") { Task { await model.devices.retryStorages(device.id) } }
                }
            } else {
                ProgressView("Reading your phone…")
            }
        case .unavailable(.claimedByOtherProcess):
            ContentUnavailableView {
                Label("Another App Is Using \(device.displayName)", systemImage: "lock.trianglebadge.exclamationmark")
            } description: {
                if let error = model.devices.releaseErrors[device.id] {
                    Text(error == .claimedByOtherProcess
                         ? String(localized: "The phone is still held by another app. Quit Image Capture and Photos, then try again.")
                         : error.localizedDescription)
                } else {
                    Text("Image Capture or Photos has taken the phone. Tether can ask it to let go.")
                }
            } actions: {
                let releasing = model.devices.releasing.contains(device.id)
                Button(releasing ? String(localized: "Releasing…") : String(localized: "Release")) {
                    Task { _ = await model.devices.release(device.id) }
                }
                .disabled(releasing)
            }
        case .unavailable(.deviceLocked):
            ContentUnavailableView {
                Label("Unlock \(device.displayName)", systemImage: "lock.iphone")
            } description: {
                Text("Unlock your phone and choose “File transfer” in the USB notification. Tether connects automatically.")
            } actions: {
                ProgressView("Waiting for you to unlock…").controlSize(.small)
            }
        case .unavailable(let error):
            ContentUnavailableView("Can’t Connect to \(device.displayName)", systemImage: "exclamationmark.triangle",
                                   description: Text(error.localizedDescription))
        }
    }
}
