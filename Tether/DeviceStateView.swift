import SwiftUI
import MTPKit
import TetherCore

/// Detail view for a phone without a browsable storage: loading, failed, held by another app, or locked.
struct DeviceStateView: View {
    @Environment(AppModel.self) private var model
    let device: DeviceInfo
    @State private var releasing = false
    @State private var releaseError: String?

    var body: some View {
        switch device.state {
        case .ready:
            if let error = model.devices.storageErrors[device.id] {
                ContentUnavailableView {
                    Label("Can’t Read \(device.displayName)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.localizedDescription)
                } actions: {
                    Button("Try Again") { Task { await model.devices.loadStorages(device.id) } }
                }
            } else {
                ProgressView("Reading your phone…")
            }
        case .unavailable(.claimedByOtherProcess):
            ContentUnavailableView {
                Label("Another App Is Using \(device.displayName)", systemImage: "lock.trianglebadge.exclamationmark")
            } description: {
                Text(releaseError ?? String(localized: "Image Capture or Photos has taken the phone. Tether can ask it to let go."))
            } actions: {
                Button(releasing ? String(localized: "Releasing…") : String(localized: "Release")) { release() }
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

    private func release() {
        guard !releasing else { return }
        releasing = true
        releaseError = nil
        Task {
            // On success the device ID changes, so this view is replaced by ContentView's selection logic.
            if let error = await model.devices.release(device.id) {
                releaseError = error == .claimedByOtherProcess
                    ? String(localized: "The phone is still held by another app. Quit Image Capture and Photos, then try again.")
                    : error.localizedDescription
            }
            releasing = false
        }
    }
}
