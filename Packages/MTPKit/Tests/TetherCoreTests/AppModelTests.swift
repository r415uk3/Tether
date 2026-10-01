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
}
