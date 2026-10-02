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
        try await eventually { provider.openCount("p1") == 1 }
        try await service.ejectDevice("p1")
        provider.releaseOpens("p1")
        _ = await scan.result
        #expect(try await service.devices().isEmpty)
        #expect(phone.isClosed, "the handle opened during the eject must be closed")
    }

    @Test func ejectingAPhoneTheFirstScanHasNotReachedHidesIt() async throws {
        let provider = FakeDeviceProvider()
        provider.attach(makePhone("p1"))
        provider.attach(makePhone("p2"))
        provider.holdOpens("p1")
        let service = LocalMTPService(provider: provider)
        let scan = Task { _ = try await service.devices() }
        try await eventually { provider.openCount("p1") == 1 }
        try await service.ejectDevice("p2") // not reached yet: the scan is stuck on p1
        provider.releaseOpens("p1")
        _ = await scan.result
        #expect(try await service.devices().map(\.id) == ["p1"])
        #expect(provider.openCount("p2") == 0)
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

    // MARK: Eject during a transfer

    /// ~1.5 s transfer: 30 KB in 1 KB chunks, 50 ms apart (LocalMTPService path, not Transfers directly).
    private func slowTransferSetup() async throws -> (FakeDevice, FileEntry, LocalMTPService) {
        let provider = FakeDeviceProvider()
        let phone = FakeDevice(id: "p1", manufacturer: "Google", model: "Pixel 9", chunkSize: 1024, chunkDelay: 0.05)
        let file = phone.addFile("big.bin", data: Data(count: 30 * 1024))
        provider.attach(phone)
        let service = LocalMTPService(provider: provider)
        _ = try await service.devices()
        return (phone, file, service)
    }

    private enum Order { case cancelThenEject, ejectThenCancel, ejectOnly }

    private func ejectDuringDownload(_ order: Order) async throws -> [String] {
        let (phone, file, service) = try await slowTransferSetup()
        let dir = try makeTempDirectory()
        let job = UUID()
        let download = Task { try await service.download(jobID: job, entry: file, deviceID: "p1", into: dir) }
        try await eventually { phone.downloadCalls == 1 }
        try await Task.sleep(for: .milliseconds(200))
        switch order {
        case .cancelThenEject:
            await service.cancel(jobID: job)
            try await service.ejectDevice("p1")
        case .ejectThenCancel:
            try await service.ejectDevice("p1")
            await service.cancel(jobID: job)
        case .ejectOnly:
            try await service.ejectDevice("p1")
        }
        if case .success = await download.result { Issue.record("the download must fail once the phone is ejected") }
        try await Task.sleep(for: .seconds(2.5)) // long enough for the whole download had it kept running
        try await eventually { phone.isClosed }
        return try contents(of: dir)
    }

    @Test func cancelThenEjectStopsTheDownload() async throws {
        let items = try await ejectDuringDownload(.cancelThenEject)
        #expect(items.isEmpty, "no final file and no .partial after cancel + eject, got \(items)")
    }

    @Test func ejectThenCancelStopsTheDownload() async throws {
        let items = try await ejectDuringDownload(.ejectThenCancel)
        #expect(items.isEmpty, "no final file and no .partial after eject + cancel, got \(items)")
    }

    @Test func ejectAloneStopsTheDownload() async throws {
        let items = try await ejectDuringDownload(.ejectOnly)
        #expect(items.isEmpty, "the ejected phone's download must not finish, got \(items)")
    }

    @Test func cancelThenEjectStopsTheUploadAndRemovesThePartialObject() async throws {
        let (phone, _, service) = try await slowTransferSetup()
        let source = try makeTempDirectory().appendingPathComponent("up.bin")
        try Data(count: 30 * 1024).write(to: source)
        let job = UUID()
        let upload = Task {
            try await service.upload(jobID: job, fileURL: source, to: FolderRef(deviceID: "p1", storageID: 1),
                                     conflict: .fail)
        }
        try await eventually { phone.children(of: FileEntry.rootID).contains { $0.name == "up.bin" } }
        try await Task.sleep(for: .milliseconds(200))
        await service.cancel(jobID: job)
        try await service.ejectDevice("p1")
        _ = await upload.result
        try await eventually { phone.isClosed }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!phone.children(of: FileEntry.rootID).contains { $0.name == "up.bin" },
                "the partial upload must be deleted from the phone")
    }
}
