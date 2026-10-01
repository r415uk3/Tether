import Foundation
import Testing
@testable import MTPKit

@Suite struct StableIdentityTests {
    let provider = FakeDeviceProvider()

    @Test func reportsDeviceIdentityAndResolvesOperations() async throws {
        let device = FakeDevice(id: "serial-ABC")
        device.addFolder("DCIM")
        provider.attach(device, as: "14-4")
        let service = LocalMTPService(provider: provider)
        #expect(try await service.devices().map(\.id) == ["serial-ABC"])
        #expect(try await service.storages(deviceID: "serial-ABC").map(\.id) == [1])
        #expect(try await service.list(FolderRef(deviceID: "serial-ABC", storageID: 1)).map(\.name) == ["DCIM"])
    }

    @Test func replugUnderNewKeyKeepsIdentity() async throws {
        let device = FakeDevice(id: "serial-ABC")
        provider.attach(device, as: "14-4")
        let service = LocalMTPService(provider: provider)
        _ = try await service.devices()
        provider.detach("14-4")
        await service.rescan()
        #expect(try await service.devices().isEmpty)
        provider.attach(device, as: "14-7")
        await service.rescan()
        #expect(try await service.devices().map(\.id) == ["serial-ABC"])
        #expect(try await service.list(FolderRef(deviceID: "serial-ABC", storageID: 1)).isEmpty)
    }

    @Test func duplicateIdentitiesFallBackToTransportKey() async throws {
        provider.attach(FakeDevice(id: "serial-SAME"), as: "k1")
        provider.attach(FakeDevice(id: "serial-SAME"), as: "k2")
        let service = LocalMTPService(provider: provider)
        #expect(Set(try await service.devices().map(\.id)) == ["serial-SAME", "k2"])
    }

    @Test func unopenableDeviceKeepsTransportKey() async throws {
        provider.attachUnavailable(AttachedDevice(id: "14-9", manufacturer: "Samsung", model: "S25"), error: .deviceLocked)
        let service = LocalMTPService(provider: provider)
        #expect(try await service.devices().map(\.id) == ["14-9"])
        await #expect(throws: MTPError.deviceLocked) { try await service.storages(deviceID: "14-9") }
    }
}
