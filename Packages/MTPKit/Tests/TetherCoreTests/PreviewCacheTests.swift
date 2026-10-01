import Foundation
import Testing
import MTPKit
@testable import TetherCore

@MainActor
@Suite struct PreviewCacheTests {
    let provider = FakeDeviceProvider()
    let device = FakeDevice(id: "p1", chunkSize: 1024, chunkDelay: 0.02)

    private func makeCache() async throws -> (PreviewCache, URL) {
        provider.attach(device)
        let service = LocalMTPService(provider: provider)
        _ = try await service.devices()
        let dir = try makeTempDirectory()
        return (PreviewCache(service: service, directory: dir), dir)
    }

    @Test func downloadsOnceAndReuses() async throws {
        let file = device.addFile("a.txt", data: Data(repeating: 7, count: 5 * 1024)) // ~100 ms, so the requests overlap
        let (cache, _) = try await makeCache()
        async let first = cache.file(for: file, deviceID: "p1")
        async let second = cache.file(for: file, deviceID: "p1") // shares the in-flight download
        let (a, b) = try await (first, second)
        #expect(a == b)
        #expect(a.lastPathComponent == "a.txt")
        #expect(try Data(contentsOf: a) == Data(repeating: 7, count: 5 * 1024))
        #expect(device.downloadCalls == 1) // shared one in-flight download
        let again = try await cache.file(for: file, deviceID: "p1")
        #expect(again == a)
        #expect(device.downloadCalls == 1) // reused, not downloaded again
        #expect(try FileManager.default.contentsOfDirectory(atPath: a.deletingLastPathComponent().path) == ["a.txt"])
    }

    @Test func sameNameDifferentItemsDoNotCollide() async throws {
        let one = device.addFolder("One")
        let two = device.addFolder("Two")
        let a = device.addFile("IMG.jpg", data: Data("first".utf8), in: one.objectID)
        let b = device.addFile("IMG.jpg", data: Data("second".utf8), in: two.objectID)
        let (cache, _) = try await makeCache()
        let urlA = try await cache.file(for: a, deviceID: "p1")
        let urlB = try await cache.file(for: b, deviceID: "p1")
        #expect(urlA != urlB)
        #expect(try Data(contentsOf: urlA) == Data("first".utf8))
        #expect(try Data(contentsOf: urlB) == Data("second".utf8))
    }

    @Test func changedItemIsDownloadedAgain() async throws {
        let file = device.addFile("a.txt", data: Data("v1".utf8))
        let (cache, _) = try await makeCache()
        let first = try await cache.file(for: file, deviceID: "p1")
        var edited = file
        edited.modified = Date(timeIntervalSince1970: 1_800_000_000) // verification doesn't compare dates
        let second = try await cache.file(for: edited, deviceID: "p1")
        #expect(first != second)
    }

    @Test func clearRemovesEverything() async throws {
        let file = device.addFile("a.txt", data: Data("x".utf8))
        let (cache, dir) = try await makeCache()
        let url = try await cache.file(for: file, deviceID: "p1")
        cache.clear()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        let again = try await cache.file(for: file, deviceID: "p1") // works after clearing
        #expect(FileManager.default.fileExists(atPath: again.path))
    }

    @Test func errorsPropagate() async throws {
        let file = device.addFile("a.txt", data: Data("x".utf8))
        let (cache, _) = try await makeCache()
        var gone = file
        gone.name = "missing.txt"
        await #expect(throws: MTPError.notFound) { try await cache.file(for: gone, deviceID: "p1") }
    }

    @Test func clearDuringDownloadCancelsItAndNewRequestStartsFresh() async throws {
        let file = device.addFile("big.bin", data: Data(repeating: 1, count: 40 * 1024)) // ~800 ms
        let (cache, _) = try await makeCache()
        let first = Task { try await cache.file(for: file, deviceID: "p1") }
        try await Task.sleep(for: .milliseconds(100))
        #expect(device.downloadCalls == 1)
        cache.clear()
        let url = try await cache.file(for: file, deviceID: "p1")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: url).count == 40 * 1024)
        #expect(device.downloadCalls == 2)
        await #expect(throws: (any Error).self) { try await first.value }
    }

    @Test func failedRequestIsNotCachedAndCanBeRetried() async throws {
        let file = device.addFile("a.txt", data: Data("x".utf8))
        let (cache, _) = try await makeCache()
        var gone = file
        gone.name = "missing.txt"
        await #expect(throws: MTPError.notFound) { try await cache.file(for: gone, deviceID: "p1") }
        await #expect(throws: MTPError.notFound) { try await cache.file(for: gone, deviceID: "p1") } // re-attempts, not a stuck entry
        let url = try await cache.file(for: file, deviceID: "p1")
        #expect(try Data(contentsOf: url) == Data("x".utf8))
    }

    @Test func cancelAllStopsDownloadsAndFreesTheDevice() async throws {
        let big = device.addFile("big.bin", data: Data(count: 200 * 1024)) // ~0.4 s with the suite's device
        let (cache, _) = try await makeCache()
        let download = Task { try await cache.file(for: big, deviceID: "p1") }
        try await eventually { cache.isDownloading(deviceID: "p1") }
        cache.cancelAll()
        #expect(cache.progress == nil)
        #expect(!cache.isDownloading(deviceID: "p1"))
        await #expect(throws: (any Error).self) { try await download.value }
        let small = device.addFile("a.txt", data: Data("x".utf8))
        let url = try await cache.file(for: small, deviceID: "p1") // the device is free again
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func progressTracksTheRunningDownload() async throws {
        let file = device.addFile("a.bin", data: Data(count: 10 * 1024)) // ~0.2 s
        provider.attach(device)
        let service = LocalMTPService(provider: provider)
        _ = try await service.devices()
        let cache = PreviewCache(service: service, directory: try makeTempDirectory())
        let seen = ProgressLog()
        await service.setEventHandler { event in
            guard case .progress(let id, _, _) = event else { return }
            Task { @MainActor in
                if cache.updateProgress(jobID: id, done: 1, total: 4) { seen.fractions.append(cache.progress) }
            }
        }
        #expect(cache.progress == nil)
        #expect(cache.updateProgress(jobID: UUID(), done: 1, total: 2) == false) // unknown job
        let download = Task { try await cache.file(for: file, deviceID: "p1") }
        try await eventually { !seen.fractions.isEmpty }
        #expect(seen.fractions.first == 0.25) // the job was known to the cache and progress was published
        _ = try await download.value
        #expect(cache.progress == nil) // nothing running any more
    }
}

@MainActor
private final class ProgressLog { var fractions: [Double?] = [] }
