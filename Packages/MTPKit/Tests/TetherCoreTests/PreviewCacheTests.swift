import Foundation
import Testing
import MTPKit
@testable import TetherCore

@MainActor
@Suite struct PreviewCacheTests {
    let provider = FakeDeviceProvider()
    let device = FakeDevice(id: "p1", chunkSize: 1024, chunkDelay: 0.002)

    private func makeCache() async throws -> (PreviewCache, URL) {
        provider.attach(device)
        let service = LocalMTPService(provider: provider)
        _ = try await service.devices()
        let dir = try makeTempDirectory()
        return (PreviewCache(service: service, directory: dir), dir)
    }

    @Test func downloadsOnceAndReuses() async throws {
        let file = device.addFile("a.txt", data: Data("hello".utf8))
        let (cache, _) = try await makeCache()
        async let first = cache.file(for: file, deviceID: "p1")
        async let second = cache.file(for: file, deviceID: "p1") // shares the in-flight download
        let (a, b) = try await (first, second)
        #expect(a == b)
        #expect(a.lastPathComponent == "a.txt")
        #expect(try Data(contentsOf: a) == Data("hello".utf8))
        let again = try await cache.file(for: file, deviceID: "p1")
        #expect(again == a)
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
}
