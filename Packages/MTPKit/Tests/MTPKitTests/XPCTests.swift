import Foundation
import Testing
@testable import MTPKit

/// Hosts an MTPService behind an in-process anonymous XPC listener.
final class XPCTestHost: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    let service: any MTPService

    init(service: any MTPService) {
        self.service = service
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        MTPXPCEndpoint.accept(connection, service: service)
        return true
    }

    func makeClient() -> XPCMTPService {
        let endpoint = Unchecked(listener.endpoint)
        return XPCMTPService { NSXPCConnection(listenerEndpoint: endpoint.value) }
    }
}

@Suite struct XPCTests {
    let provider = FakeDeviceProvider()
    let device = FakeDevice(id: "p1")

    private func makeClient() -> (XPCMTPService, XPCTestHost) {
        provider.attach(device)
        let host = XPCTestHost(service: LocalMTPService(provider: provider))
        return (host.makeClient(), host)
    }

    @Test func listsDevicesAndFolders() async throws {
        device.addFolder("DCIM")
        let (client, host) = makeClient()
        let devices = try await client.devices()
        #expect(devices.map(\.id) == ["p1"])
        #expect(try await client.storages(deviceID: "p1").first?.id == 1)
        #expect(try await client.list(FolderRef(deviceID: "p1", storageID: 1)).map(\.name) == ["DCIM"])
        withExtendedLifetime(host) {}
    }

    @Test func serverErrorsArriveTyped() async throws {
        let (client, host) = makeClient()
        await #expect(throws: MTPError.deviceDisconnected) { try await client.storages(deviceID: "nope") }
        withExtendedLifetime(host) {}
    }

    @Test func downloadDeliversProgressEvents() async throws {
        let file = device.addFile("a.bin", data: Data(count: 10_000))
        let (client, host) = makeClient()
        let events = Log<ServiceEvent>()
        await client.setEventHandler { events.append($0) }
        _ = try await client.devices()
        let job = UUID()
        let url = try await client.download(jobID: job, entry: file, deviceID: "p1", into: try makeTempDirectory())
        #expect(try Data(contentsOf: url).count == 10_000)
        try await eventually { events.items.contains(.progress(jobID: job, done: 10_000, total: 10_000)) }
        withExtendedLifetime(host) {}
    }

    @Test func restartFailsPendingCallAndReconnects() async throws {
        let (client, host) = makeClient()
        let events = Log<ServiceEvent>()
        await client.setEventHandler { events.append($0) }
        _ = try await client.devices()
        device.inject(.hang)
        let pending = Task { try await client.list(FolderRef(deviceID: "p1", storageID: 1)) }
        try await Task.sleep(for: .milliseconds(100))
        await client.restart()
        await #expect(throws: MTPError.serviceInterrupted) { try await pending.value }
        try await eventually { events.items.contains(.interrupted) }
        device.releaseHang()
        #expect(try await client.devices().map(\.id) == ["p1"])
        withExtendedLifetime(host) {}
    }

    @Test func uploadPolicyCrossesXPC() async throws {
        device.addFile("a.txt", data: Data("old".utf8))
        let (client, host) = makeClient()
        _ = try await client.devices()
        let file = try makeTempDirectory().appendingPathComponent("a.txt")
        try Data("new".utf8).write(to: file)
        let entry = try await client.upload(jobID: UUID(), fileURL: file, to: FolderRef(deviceID: "p1", storageID: 1),
                                            conflict: .keepBoth)
        #expect(entry.name == "a 2.txt")
        withExtendedLifetime(host) {}
    }

    @Test func requestsRoundTripThroughCodec() throws {
        let request = XPCRequest.upload(jobID: UUID(), fileURL: URL(fileURLWithPath: "/tmp/a b.txt"),
                                        folder: FolderRef(deviceID: "d", storageID: 2, folderID: 9), conflict: .keepBoth)
        let decoded = try XPCCodec.decode(XPCRequest.self, from: XPCCodec.encode(request))
        #expect(decoded == request)
    }

    @Test func thumbnailCrossesXPC() async throws {
        let photo = device.addFile("a.jpg", data: Data(count: 10))
        device.setThumbnail(Data("thumb".utf8), for: photo.objectID)
        let (client, host) = makeClient()
        _ = try await client.devices()
        let folder = FolderRef(deviceID: "p1", storageID: 1)
        #expect(try await client.thumbnail(objectID: photo.objectID, in: folder) == Data("thumb".utf8))
        let plain = device.addFile("b.txt", data: Data(count: 1))
        #expect(try await client.thumbnail(objectID: plain.objectID, in: folder) == nil)
        withExtendedLifetime(host) {}
    }

    @Test func releaseCrossesXPC() async throws {
        provider.attachClaimed(FakeDevice(id: "serial-B"), as: "14-5")
        let (client, host) = makeClient()
        _ = try await client.devices()
        try await client.releaseDevice("14-5")
        #expect(try await client.devices().contains { $0.id == "serial-B" && $0.state == .ready })
        withExtendedLifetime(host) {}
    }

    @Test func ejectCrossesXPC() async throws {
        let (client, host) = makeClient()
        #expect(try await client.devices().map(\.id) == ["p1"])
        try await client.ejectDevice("p1")
        #expect(try await client.devices().isEmpty)
        withExtendedLifetime(host) {}
    }

    @Test func diagnosticsCrossXPC() async throws {
        let log = DiagnosticLog()
        log.record("hello", category: "test")
        let service = LocalMTPService(provider: provider, log: log)
        let host = XPCTestHost(service: service)
        let lines = try await host.makeClient().diagnostics()
        #expect(lines.count == 1 && lines[0].hasSuffix("[test] hello"))
        withExtendedLifetime(host) {}
    }
}
