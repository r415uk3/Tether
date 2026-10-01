import Foundation
import Testing
@testable import MTPKit

@Suite struct DiagnosticLogTests {
    @Test func keepsTheNewestLinesUpToCapacity() {
        let log = DiagnosticLog(capacity: 3)
        for i in 1...5 { log.record("event \(i)", category: "test") }
        let lines = log.snapshot()
        #expect(lines.count == 3)
        #expect(lines.map { $0.hasSuffix("[test] event 3") || $0.hasSuffix("[test] event 4") || $0.hasSuffix("[test] event 5") } == [true, true, true])
        #expect(lines.first!.hasSuffix("event 3"))
        #expect(lines.last!.hasSuffix("event 5"))
    }

    @Test func serviceLogsOpenFailuresAndReturnsTheLog() async throws {
        let provider = FakeDeviceProvider()
        provider.attachUnavailable(AttachedDevice(id: "k", manufacturer: "Samsung", model: "S25"), error: .deviceLocked)
        let service = LocalMTPService(provider: provider, log: DiagnosticLog())
        _ = try await service.devices()
        let lines = try await service.diagnostics()
        #expect(lines.contains { $0.contains("Open failed for S25") })
    }

    @Test func serviceLogDoesNotLeakNamesInErrors() async throws {
        let provider = FakeDeviceProvider()
        provider.attachUnavailable(AttachedDevice(id: "k", manufacturer: "Samsung", model: "S25"),
                                   error: .nameConflict("secret-name.jpg"))
        provider.attachUnavailable(AttachedDevice(id: "j", manufacturer: "Samsung", model: "S24"),
                                   error: .underlying(code: 7, message: "cannot open /Users/me/secret-name.jpg"))
        let service = LocalMTPService(provider: provider, log: DiagnosticLog())
        _ = try await service.devices()
        let text = try await service.diagnostics().joined(separator: "\n")
        #expect(text.contains("Open failed for S25"))
        #expect(text.contains("Open failed for S24"))
        #expect(!text.contains("secret-name"))
    }

    @Test func deviceInfoCarriesOSVersion() throws {
        let info = DeviceInfo(id: "x", manufacturer: "Google", model: "Pixel 9", state: .ready, osVersion: "15")
        let decoded = try JSONDecoder().decode(DeviceInfo.self, from: JSONEncoder().encode(info))
        #expect(decoded.osVersion == "15")
    }

    @Test func deviceInfoDecodesOlderPayloadWithoutOSVersion() throws {
        let old = DeviceInfo(id: "x", manufacturer: "Google", model: "Pixel 9", state: .ready)
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json["osVersion"] = nil
        let decoded = try JSONDecoder().decode(DeviceInfo.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.osVersion == nil)
    }
}
