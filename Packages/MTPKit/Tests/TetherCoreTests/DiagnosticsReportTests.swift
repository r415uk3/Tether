import Foundation
import Testing
import MTPKit
@testable import TetherCore

@Suite struct DiagnosticsReportTests {
    @Test func reportListsVersionsDevicesAndLogs() {
        let devices = [
            DeviceInfo(id: "serial-SECRET", manufacturer: "Google", model: "Pixel 9", state: .ready, osVersion: "15"),
            DeviceInfo(id: "14-9", manufacturer: "Samsung", model: "Galaxy S25", state: .unavailable(.deviceLocked)),
        ]
        let report = DiagnosticsReport.make(appVersion: "0.2.0 (7)", macOSVersion: "27.0", devices: devices,
                                            appLog: ["a1"], helperLog: ["h1", "h2"])
        #expect(report.contains("Tether 0.2.0 (7)"))
        #expect(report.contains("macOS 27.0"))
        #expect(report.contains("Google Pixel 9 — Android 15 — ready"))
        #expect(report.contains("Samsung Galaxy S25 — Android ? — unavailable:"))
        #expect(report.contains("a1"))
        #expect(report.contains("h2"))
        #expect(!report.contains("SECRET")) // no serials
    }

    @Test func reportWithoutHelperOrDevices() {
        let report = DiagnosticsReport.make(appVersion: "1", macOSVersion: "15.0", devices: [], appLog: [], helperLog: nil)
        #expect(report.contains("No phones connected"))
        #expect(report.contains("Helper log unavailable"))
    }

    @MainActor
    @Test func reportAfterFailedTransferHasNeitherSerialNorFileName() async throws {
        let phone = FakeDevice(id: "serial-SECRET123", manufacturer: "Google", model: "Pixel 9")
        let file = phone.addFile("private-holiday-photo.jpg", data: Data(repeating: 1, count: 64))
        phone.inject(.fail(.nameConflict("private-holiday-photo.jpg")))
        let provider = FakeDeviceProvider()
        provider.attach(phone)
        let log = DiagnosticLog()
        let service = LocalMTPService(provider: provider, log: log)
        let queue = TransferQueue(service: service, log: log)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("tether-diag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let devices = try await service.devices()
        queue.enqueueDownload(file, deviceID: "serial-SECRET123", into: destination)
        for _ in 0..<500 where queue.hasActiveJobs || queue.jobs.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let failed = queue.jobs.contains { if case .failed = $0.state { true } else { false } }
        #expect(failed)

        let report = DiagnosticsReport.make(appVersion: "1", macOSVersion: "15.0", devices: devices,
                                            appLog: log.snapshot(), helperLog: try await service.diagnostics())
        #expect(report.contains("Transfer failed (download, 64 bytes)"))
        #expect(report.contains("Pixel 9"))
        #expect(!report.contains("SECRET123"))
        #expect(!report.contains("private-holiday-photo"))
    }
}
