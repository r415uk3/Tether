import Foundation
import Testing
import MTPKit
@testable import TetherCore

@MainActor
@Suite struct AppModelTests {
    let provider = FakeDeviceProvider()
    let device = FakeDevice(id: "p1", chunkSize: 1024, chunkDelay: 0.002)

    @Test func startLoadsDevicesAndRoutesProgress() async throws {
        provider.attach(device)
        let file = device.addFile("big.bin", data: Data(count: 100_000))
        let model = AppModel(service: LocalMTPService(provider: provider))
        await model.start()
        #expect(model.devices.devices.map(\.id) == ["p1"])
        model.transfers.enqueueDownload(file, deviceID: "p1", into: try makeTempDirectory())
        try await eventually { model.transfers.jobs[0].done > 0 }
        try await eventually { if case .finished = model.transfers.jobs[0].state { true } else { false } }
        try await eventually { model.transfers.jobs[0].fraction == 1 }
    }

    @Test func deviceEventsUpdateStore() async throws {
        provider.attach(device)
        let service = LocalMTPService(provider: provider)
        let model = AppModel(service: service)
        await model.start()
        provider.detach("p1")
        await service.rescan()
        try await eventually { model.devices.devices.isEmpty }
    }

    @Test func finishedUploadRefreshesFolder() async throws {
        provider.attach(device)
        let model = AppModel(service: LocalMTPService(provider: provider))
        await model.start()
        let folder = FolderRef(deviceID: "p1", storageID: 1)
        await model.devices.refresh(folder)
        let file = try makeTempDirectory().appendingPathComponent("up.txt")
        try Data("up".utf8).write(to: file)
        model.transfers.enqueueUpload(file, to: folder)
        try await eventually { model.devices.listings[folder]?.entries.map(\.name) == ["up.txt"] }
    }

    @Test func browsingDuringTransferDoesNotTimeOutOrRestart() async throws {
        let slow = FakeDevice(id: "p1", chunkSize: 8192, chunkDelay: 0.01)
        provider.attach(slow)
        let file = slow.addFile("big.bin", data: Data(count: 1_000_000))
        let model = AppModel(service: LocalMTPService(provider: provider))
        model.devices.listTimeout = .milliseconds(300)
        await model.start()
        let root = FolderRef(deviceID: "p1", storageID: 1)
        model.transfers.enqueueDownload(file, deviceID: "p1", into: try makeTempDirectory())
        try await eventually { model.transfers.jobs[0].done > 0 }
        await model.devices.refresh(root)
        #expect(model.devices.listings[root]?.error == nil)
        #expect(model.devices.listings[root]?.entries.map(\.name) == ["big.bin"])
        #expect(provider.openCount("p1") == 1)
        try await eventually(timeout: .seconds(30)) {
            if case .finished = model.transfers.jobs[0].state { true } else { false }
        }
    }

    /// Replugs `phone` under a new USB key and waits until the model sees it ready again.
    private func replug(_ phone: FakeDevice, from old: String, to new: String, service: LocalMTPService,
                        model: AppModel) async throws {
        provider.detach(old)
        await service.rescan()
        try await eventually { model.devices.devices.isEmpty }
        provider.attach(phone, as: new)
        await service.rescan()
        try await eventually { model.devices.devices.map(\.state) == [.ready] }
        try await eventually { model.devices.storages[phone.info.id] != nil }
    }

    @Test func uploadRetriedAfterReplugFailsWithoutTouchingDevice() async throws {
        let phone = FakeDevice(id: "serial-ABC")
        provider.attach(phone, as: "14-4")
        let service = LocalMTPService(provider: provider)
        let model = AppModel(service: service)
        await model.start()
        let folder = FolderRef(deviceID: "serial-ABC", storageID: 1)
        let file = try makeTempDirectory().appendingPathComponent("up.txt")
        try Data("up".utf8).write(to: file)
        try await eventually { model.devices.storages["serial-ABC"] != nil } // so the fault hits the transfer
        phone.inject(.fail(.deviceDisconnected))
        let id = model.transfers.enqueueUpload(file, to: folder)
        try await eventually { model.transfers.jobs[0].state == .failed(.deviceDisconnected) }
        try await replug(phone, from: "14-4", to: "14-7", service: service, model: model)

        model.transfers.retry(id)
        let stale = MTPError.underlying(code: -6, message: String(
            localized: "The phone was reconnected, so this folder may have changed. Upload the item again."))
        try await eventually { model.transfers.jobs[0].state == .failed(stale) }
        #expect(phone.children(of: FileEntry.rootID).isEmpty)

        // A new upload after the replug works.
        model.transfers.enqueueUpload(file, to: folder)
        try await eventually { if case .finished = model.transfers.jobs[1].state { true } else { false } }
        #expect(phone.children(of: FileEntry.rootID).map(\.name) == ["up.txt"])
    }

    @Test func downloadRetriedAfterReplugStillWorks() async throws {
        let phone = FakeDevice(id: "serial-ABC")
        provider.attach(phone, as: "14-4")
        let entry = phone.addFile("a.txt", data: Data("x".utf8))
        let service = LocalMTPService(provider: provider)
        let model = AppModel(service: service)
        await model.start()
        try await eventually { model.devices.storages["serial-ABC"] != nil } // so the fault hits the transfer
        phone.inject(.fail(.deviceDisconnected))
        let id = model.transfers.enqueueDownload(entry, deviceID: "serial-ABC", into: try makeTempDirectory())
        try await eventually { model.transfers.jobs[0].state == .failed(.deviceDisconnected) }
        try await replug(phone, from: "14-4", to: "14-7", service: service, model: model)
        model.transfers.retry(id)
        try await eventually { if case .finished = model.transfers.jobs[0].state { true } else { false } }
    }
}
