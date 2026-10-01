import Foundation
import Testing
@testable import MTPKit

@Suite struct ReleaseTests {
    let provider = FakeDeviceProvider()

    @Test func releaseFreesAClaimedDevice() async throws {
        provider.attachClaimed(FakeDevice(id: "serial-A"), as: "14-4")
        let service = LocalMTPService(provider: provider)
        #expect(try await service.devices().first?.state == .unavailable(.claimedByOtherProcess))
        try await service.releaseDevice("14-4")
        #expect(provider.releaseClaimsCalls == 1)
        let devices = try await service.devices()
        #expect(devices.map(\.id) == ["serial-A"])
        #expect(devices.first?.state == .ready)
    }

    @Test func releaseThatDoesNotFreeTheDeviceKeepsItClaimed() async throws {
        provider.attachClaimed(FakeDevice(id: "serial-A"), as: "14-4", releasable: false)
        let service = LocalMTPService(provider: provider)
        _ = try await service.devices()
        await #expect(throws: MTPError.claimedByOtherProcess) { try await service.releaseDevice("14-4") }
        #expect(try await service.devices().first?.state == .unavailable(.claimedByOtherProcess))
    }

    @Test func nothingToReleaseIsReported() async throws {
        provider.attachUnavailable(AttachedDevice(id: "14-9", manufacturer: "S", model: "S25"), error: .deviceLocked)
        let service = LocalMTPService(provider: provider) // FakeDeviceProvider releases nothing here
        _ = try await service.devices()
        await #expect(throws: MTPError.deviceLocked) { try await service.releaseDevice("14-9") }
        #expect(provider.releaseClaimsCalls == 0)
    }

    @Test func releasingAReadyDeviceSignalsNothing() async throws {
        provider.attach(FakeDevice(id: "serial-R"))
        let service = LocalMTPService(provider: provider)
        _ = try await service.devices()
        try await service.releaseDevice("serial-R")
        #expect(provider.releaseClaimsCalls == 0)
    }

    @Test func releasingAnUnknownDeviceIsDisconnected() async throws {
        let service = LocalMTPService(provider: provider)
        await #expect(throws: MTPError.deviceDisconnected) { try await service.releaseDevice("nope") }
        #expect(provider.releaseClaimsCalls == 0)
    }

    @Test func agentLookupDoesNotCrashAndFindsNoFakeProcess() {
        // Real libproc call; on a test machine ptpcamerad may or may not run, but a bogus name never matches.
        _ = ImageCaptureAgent.runningProcessIDs()
        #expect(ImageCaptureAgent.processIDs(named: "tether-no-such-process-\(UUID().uuidString.prefix(6))").isEmpty)
    }
}
