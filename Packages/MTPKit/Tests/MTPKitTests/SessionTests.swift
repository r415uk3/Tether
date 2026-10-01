import Foundation
import Testing
@testable import MTPKit

@Suite struct SessionTests {
    let provider = FakeDeviceProvider()
    let device = FakeDevice(id: "serial-ABC")

    private func makeService() async throws -> (LocalMTPService, UUID) {
        provider.attach(device, as: "14-4")
        let service = LocalMTPService(provider: provider)
        let session = try #require(try await service.devices().first?.session)
        return (service, session)
    }

    @Test func eachOpenGetsANewSession() async throws {
        let (service, first) = try await makeService()
        provider.detach("14-4")
        await service.rescan()
        provider.attach(device, as: "14-7")
        await service.rescan()
        let second = try #require(try await service.devices().first?.session)
        #expect(first != second)
    }

    @Test func staleSessionIsRefusedForFolderCalls() async throws {
        let (service, session) = try await makeService()
        device.addFolder("DCIM")
        let current = FolderRef(deviceID: "serial-ABC", storageID: 1, session: session)
        let stale = FolderRef(deviceID: "serial-ABC", storageID: 1, session: UUID())
        let unchecked = FolderRef(deviceID: "serial-ABC", storageID: 1)
        #expect(try await service.list(current).map(\.name) == ["DCIM"])
        #expect(try await service.list(unchecked).map(\.name) == ["DCIM"])
        await #expect(throws: MTPError.phoneReconnected) { try await service.list(stale) }
        await #expect(throws: MTPError.phoneReconnected) { try await service.createFolder(named: "X", in: stale) }
        let file = try makeTempDirectory().appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: file)
        await #expect(throws: MTPError.phoneReconnected) {
            try await service.upload(jobID: UUID(), fileURL: file, to: stale, conflict: .fail)
        }
        #expect(device.children(of: FileEntry.rootID).map(\.name) == ["DCIM"])
    }

    @Test func staleSessionRenameAndDeleteAreRefused() async throws {
        let (service, _) = try await makeService()
        let file = device.addFile("a.txt", data: Data("a".utf8))
        let stale = FolderRef(deviceID: "serial-ABC", storageID: 1, session: UUID())
        await #expect(throws: MTPError.phoneReconnected) { try await service.rename(file, in: stale, to: "b.txt") }
        await #expect(throws: MTPError.phoneReconnected) { try await service.delete(file, in: stale) }
        #expect(device.children(of: FileEntry.rootID).map(\.name) == ["a.txt"])
    }

    @Test func renameAndDeleteVerifyTheEntry() async throws {
        let (service, session) = try await makeService()
        let file = device.addFile("a.txt", data: Data("a".utf8))
        let folder = FolderRef(deviceID: "serial-ABC", storageID: 1, session: session)
        var impostor = file
        impostor.name = "someone-else.txt" // the handle now names a different item
        await #expect(throws: MTPError.notFound) { try await service.rename(impostor, in: folder, to: "b.txt") }
        await #expect(throws: MTPError.notFound) { try await service.delete(impostor, in: folder) }
        #expect(device.children(of: FileEntry.rootID).map(\.name) == ["a.txt"])
        try await service.rename(file, in: folder, to: "b.txt")
        var renamed = file
        renamed.name = "b.txt"
        try await service.delete(renamed, in: folder)
        #expect(device.children(of: FileEntry.rootID).isEmpty)
    }
}
