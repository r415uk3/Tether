import Foundation
import Testing
@testable import MTPKit

@Suite struct EjectTests {
    private func makePhone(_ id: String = "p1") -> FakeDevice {
        FakeDevice(id: id, manufacturer: "Google", model: "Pixel 9")
    }

    @Test func ejectRemovesThePhone() async throws {
        let provider = FakeDeviceProvider()
        provider.attach(makePhone())
        let service = LocalMTPService(provider: provider)
        #expect(try await service.devices().map(\.id) == ["p1"])
        try await service.ejectDevice("p1")
        #expect(try await service.devices().isEmpty)
    }

    @Test func ejectedDeviceStaysHiddenUntilUnplugged() async throws {
        let provider = FakeDeviceProvider()
        let phone = makePhone()
        provider.attach(phone)
        let service = LocalMTPService(provider: provider)
        _ = try await service.devices()
        try await service.ejectDevice("p1")
        await service.rescan()
        #expect(try await service.devices().isEmpty, "still plugged in: must stay ejected")
        #expect(provider.openCount("p1") == 1)
        provider.detach("p1")
        await service.rescan()
        provider.attach(phone)
        await service.rescan()
        #expect(try await service.devices().map(\.id) == ["p1"], "replugged: must come back")
        #expect(provider.openCount("p1") == 2)
    }

    @Test func ejectClosesTheConnection() async throws {
        let provider = FakeDeviceProvider()
        let phone = makePhone()
        provider.attach(phone)
        let service = LocalMTPService(provider: provider)
        _ = try await service.devices()
        try await service.ejectDevice("p1")
        let folder = FolderRef(deviceID: "p1", storageID: 1, folderID: FileEntry.rootID, session: nil)
        await #expect(throws: MTPError.deviceDisconnected) { _ = try await service.list(folder) }
    }

    @Test func ejectDuringOpenClosesTheHandle() async throws {
        let provider = FakeDeviceProvider()
        let phone = makePhone()
        provider.attach(phone)
        provider.holdOpens("p1")
        let service = LocalMTPService(provider: provider)
        let scan = Task { _ = try await service.devices() }
        try await Task.sleep(for: .milliseconds(50))
        try await service.ejectDevice("p1")
        provider.releaseOpens("p1")
        _ = await scan.result
        #expect(try await service.devices().isEmpty)
        #expect(phone.isClosed, "the handle opened during the eject must be closed")
    }

    @Test func ejectingAnUnknownPhoneFails() async throws {
        let service = LocalMTPService(provider: FakeDeviceProvider())
        await #expect(throws: MTPError.deviceDisconnected) { try await service.ejectDevice("nope") }
    }

    @Test func ejectingALockedPhoneHidesIt() async throws {
        let provider = FakeDeviceProvider()
        provider.attachUnavailable(AttachedDevice(id: "g1", manufacturer: "Samsung", model: "Galaxy"), error: .deviceLocked)
        let service = LocalMTPService(provider: provider)
        #expect(try await service.devices().count == 1)
        try await service.ejectDevice("g1")
        #expect(try await service.devices().isEmpty)
    }
}
