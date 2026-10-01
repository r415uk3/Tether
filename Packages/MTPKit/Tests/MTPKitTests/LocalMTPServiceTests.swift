import Foundation
import Testing
@testable import MTPKit

@Suite struct LocalMTPServiceTests {
    let provider = FakeDeviceProvider()
    let device = FakeDevice(id: "p1", chunkSize: 1024, chunkDelay: 0.005)
    let events = Log<ServiceEvent>()

    private func makeService() async -> LocalMTPService {
        let service = LocalMTPService(provider: provider)
        let events = self.events
        await service.setEventHandler { events.append($0) }
        return service
    }

    @Test func listsReadyAndUnavailableDevices() async throws {
        provider.attach(device)
        provider.attachUnavailable(AttachedDevice(id: "p2", manufacturer: "Samsung", model: "S25"), error: .deviceLocked)
        let service = await makeService()
        let devices = try await service.devices()
        #expect(devices.map(\.id) == ["p1", "p2"])
        #expect(devices[0].state == .ready)
        #expect(devices[1].state == .unavailable(.deviceLocked))
        #expect(await service.hasUnavailableDevices)
        #expect(events.items.contains(.devicesChanged(devices)))
        await #expect(throws: MTPError.deviceLocked) { try await service.storages(deviceID: "p2") }
    }

    @Test func unavailableDeviceBecomesReadyOnRescan() async throws {
        provider.attachUnavailable(AttachedDevice(id: "p1", manufacturer: "Google", model: "Pixel 9"), error: .deviceLocked)
        let service = await makeService()
        _ = try await service.devices()
        provider.attach(device)
        await service.rescan()
        #expect(try await service.devices().first?.state == .ready)
        #expect(!(await service.hasUnavailableDevices))
    }

    @Test func firstCallWithoutPriorScanSucceeds() async throws {
        provider.attach(device)
        device.addFile("a.txt", data: Data("x".utf8))
        let service = LocalMTPService(provider: provider)
        let entries = try await service.list(FolderRef(deviceID: "p1", storageID: 1))
        #expect(entries.map(\.name) == ["a.txt"])
    }

    @Test func concurrentFirstCallsShareOneScan() async throws {
        provider.attach(device)
        device.addFile("a.txt", data: Data("x".utf8))
        provider.holdOpens("p1")
        let service = LocalMTPService(provider: provider)
        let provider = self.provider
        let listing = Task { try await service.list(FolderRef(deviceID: "p1", storageID: 1)) }
        let devices = Task { try await service.devices() }
        try await eventually { provider.openCount("p1") == 1 }
        try await Task.sleep(for: .milliseconds(50))
        provider.releaseOpens("p1")
        #expect(try await listing.value.map(\.name) == ["a.txt"])
        #expect(try await devices.value.map(\.id) == ["p1"])
        #expect(provider.openCount("p1") == 1)
    }

    @Test func listsFolders() async throws {
        provider.attach(device)
        device.addFolder("DCIM")
        let service = await makeService()
        _ = try await service.devices()
        let entries = try await service.list(FolderRef(deviceID: "p1", storageID: 1))
        #expect(entries.map(\.name) == ["DCIM"])
    }

    @Test func detachFailsInFlightOperation() async throws {
        provider.attach(device)
        let service = await makeService()
        _ = try await service.devices()
        device.inject(.hang)
        let listing = Task { try await service.list(FolderRef(deviceID: "p1", storageID: 1)) }
        try await Task.sleep(for: .milliseconds(50))
        provider.detach("p1")
        await service.rescan()
        await #expect(throws: MTPError.deviceDisconnected) { try await listing.value }
        #expect(try await service.devices().isEmpty)
        await #expect(throws: MTPError.deviceDisconnected) { try await service.storages(deviceID: "p1") }
        device.releaseHang()
    }

    @Test func restartInterruptsHungOperationAndReopens() async throws {
        provider.attach(device)
        let service = await makeService()
        _ = try await service.devices()
        device.inject(.hang)
        let listing = Task { try await service.list(FolderRef(deviceID: "p1", storageID: 1)) }
        try await Task.sleep(for: .milliseconds(50))
        await service.restart()
        await #expect(throws: MTPError.serviceInterrupted) { try await listing.value }
        #expect(events.items.contains(.interrupted))
        #expect(provider.openCount("p1") == 2)
        device.releaseHang()
        #expect(try await service.list(FolderRef(deviceID: "p1", storageID: 1)).isEmpty)
    }

    @Test func downloadReportsProgressAndCanBeCancelled() async throws {
        provider.attach(device)
        let file = device.addFile("big.bin", data: Data(count: 200 * 1024))
        let service = await makeService()
        _ = try await service.devices()
        let dir = try makeTempDirectory()
        let job = UUID()
        let download = Task { try await service.download(jobID: job, entry: file, deviceID: "p1", into: dir) }
        let events = self.events
        try await eventually { events.items.contains { if case .progress(job, _, _) = $0 { true } else { false } } }
        await service.cancel(jobID: job)
        await #expect(throws: MTPError.cancelled) { try await download.value }
        #expect(try contents(of: dir).isEmpty)
    }

    @Test func downloadCompletesWithFinalProgress() async throws {
        provider.attach(device)
        let file = device.addFile("small.bin", data: Data(count: 4096))
        let service = await makeService()
        _ = try await service.devices()
        let job = UUID()
        let url = try await service.download(jobID: job, entry: file, deviceID: "p1", into: try makeTempDirectory())
        #expect(try Data(contentsOf: url).count == 4096)
        #expect(events.items.contains(.progress(jobID: job, done: 4096, total: 4096)))
    }

    @Test func cancelBeforeStartSkipsTransfer() async throws {
        provider.attach(device)
        let file = device.addFile("a.bin", data: Data(count: 4096))
        let service = await makeService()
        _ = try await service.devices()
        device.inject(.hang)
        let blocker = Task { try await service.list(FolderRef(deviceID: "p1", storageID: 1)) }
        try await Task.sleep(for: .milliseconds(50))
        let dir = try makeTempDirectory()
        let job = UUID()
        let download = Task { try await service.download(jobID: job, entry: file, deviceID: "p1", into: dir) }
        try await Task.sleep(for: .milliseconds(20))
        await service.cancel(jobID: job)
        device.releaseHang()
        _ = try await blocker.value
        await #expect(throws: MTPError.cancelled) { try await download.value }
        #expect(try contents(of: dir).isEmpty)
        let events = self.events
        #expect(!events.items.contains { if case .progress(job, _, _) = $0 { true } else { false } })
    }

    @Test func mutationsReachTheDevice() async throws {
        provider.attach(device)
        let service = await makeService()
        _ = try await service.devices()
        let folder = FolderRef(deviceID: "p1", storageID: 1)
        let created = try await service.createFolder(named: "New", in: folder)
        try await service.rename(objectID: created.objectID, deviceID: "p1", to: "Renamed")
        #expect(try await service.list(folder).map(\.name) == ["Renamed"])
        try await service.delete(objectID: created.objectID, deviceID: "p1")
        #expect(try await service.list(folder).isEmpty)
    }

    @Test func uploadsIntoFolder() async throws {
        provider.attach(device)
        let service = await makeService()
        _ = try await service.devices()
        let file = try makeTempDirectory().appendingPathComponent("a.txt")
        try Data("hi".utf8).write(to: file)
        let entry = try await service.upload(jobID: UUID(), fileURL: file, to: FolderRef(deviceID: "p1", storageID: 1))
        #expect(device.data(of: entry.objectID) == Data("hi".utf8))
    }

    @Test func detachDuringHeldOpenLeavesNoGhost() async throws {
        provider.attach(device)
        provider.holdOpens("p1")
        let service = await makeService()
        let provider = self.provider
        let scan = Task { await service.rescan() }
        try await eventually { provider.openCount("p1") == 1 }
        provider.detach("p1")
        await service.rescan()
        provider.releaseOpens("p1")
        await scan.value
        #expect(try await service.devices().isEmpty)
        #expect(!(await service.hasUnavailableDevices))
    }

    @Test func detachDuringHeldOpenDiscardsFailedOpen() async throws {
        provider.attachUnavailable(AttachedDevice(id: "p1", manufacturer: "Google", model: "Pixel 9"), error: .deviceLocked)
        provider.holdOpens("p1")
        let service = await makeService()
        let provider = self.provider
        let scan = Task { await service.rescan() }
        try await eventually { provider.openCount("p1") == 1 }
        provider.detach("p1")
        await service.rescan()
        provider.releaseOpens("p1")
        await scan.value
        #expect(try await service.devices().isEmpty)
        #expect(!(await service.hasUnavailableDevices))
    }

    @Test func replugDuringHeldOpenDiscardsStaleHandle() async throws {
        provider.attach(device)
        provider.holdOpens("p1")
        let service = await makeService()
        let provider = self.provider
        let scan = Task { await service.rescan() }
        try await eventually { provider.openCount("p1") == 1 }
        provider.detach("p1")
        await service.rescan()
        provider.attach(device)
        await service.rescan()
        provider.releaseOpens("p1")
        await scan.value
        #expect(try await service.devices().isEmpty)
        await service.rescan()
        #expect(provider.openCount("p1") == 2)
        #expect(try await service.devices().first?.state == .ready)
        #expect(try await service.devices().count == 1)
    }

    @Test func restartRecoversHungOpen() async throws {
        provider.attach(device)
        provider.holdOpens("p1")
        let service = await makeService()
        let provider = self.provider
        let scan = Task { await service.rescan() }
        try await eventually { provider.openCount("p1") == 1 }
        await service.restart()
        #expect(provider.openCount("p1") == 2)
        #expect(try await service.devices().first?.state == .ready)
        provider.releaseOpens("p1")
        await scan.value
        let devices = try await service.devices()
        #expect(devices.count == 1)
        #expect(devices.first?.state == .ready)
        #expect(try await service.list(FolderRef(deviceID: "p1", storageID: 1)).isEmpty)
    }
}
