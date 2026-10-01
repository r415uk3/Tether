import Foundation
import Testing
import MTPKit
@testable import TetherCore

@MainActor
final class TestClock {
    var date = Date(timeIntervalSince1970: 1_700_000_000)
}

@MainActor
@Suite struct ThumbnailStoreTests {
    let provider = FakeDeviceProvider()
    let device = FakeDevice(id: "p1")
    var folder: FolderRef { FolderRef(deviceID: "p1", storageID: 1) }

    let clock = TestClock()

    private func makeStore(directory: URL? = nil) async throws -> (ThumbnailStore, LocalMTPService) {
        provider.attach(device)
        let service = LocalMTPService(provider: provider)
        _ = try await service.devices()
        return (ThumbnailStore(service: service, directory: directory, now: { [clock] in clock.date }), service)
    }

    @Test func fetchesOnceAndCachesInMemory() async throws {
        let photo = device.addFile("a.jpg", data: Data(count: 10))
        device.setThumbnail(Data("thumb".utf8), for: photo.objectID)
        let (store, _) = try await makeStore()
        store.request(photo, in: folder)
        store.request(photo, in: folder) // deduplicated while in flight
        try await eventually { store.cached(photo, deviceID: "p1") != nil }
        store.request(photo, in: folder)
        #expect(store.cached(photo, deviceID: "p1") == Data("thumb".utf8))
        #expect(device.thumbnailCalls == 1)
        #expect(store.version == 1)
    }

    @Test func diskCacheSurvivesANewStore() async throws {
        let photo = device.addFile("a.jpg", data: Data(count: 10))
        device.setThumbnail(Data("thumb".utf8), for: photo.objectID)
        let dir = try makeTempDirectory().appendingPathComponent("not-yet-created")
        let (first, service) = try await makeStore(directory: dir)
        first.request(photo, in: folder)
        try await eventually { first.cached(photo, deviceID: "p1") != nil }
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(ItemKey(entry: photo, deviceID: "p1").fileName).path))
        let second = ThumbnailStore(service: service, directory: dir, now: { [clock] in clock.date })
        second.request(photo, in: folder)
        try await eventually { second.cached(photo, deviceID: "p1") != nil }
        #expect(device.thumbnailCalls == 1)
    }

    @Test func missingThumbnailIsNotRefetchedUntilItExpires() async throws {
        let photo = device.addFile("a.jpg", data: Data(count: 10)) // no thumbnail set
        let (store, _) = try await makeStore()
        store.request(photo, in: folder)
        try await eventually { device.thumbnailCalls == 1 && store.pendingCount == 0 }
        clock.date.addTimeInterval(9 * 60)
        store.request(photo, in: folder)
        try await eventually { store.pendingCount == 0 }
        #expect(device.thumbnailCalls == 1)
        #expect(store.cached(photo, deviceID: "p1") == nil)
        clock.date.addTimeInterval(2 * 60)
        device.setThumbnail(Data("late".utf8), for: photo.objectID)
        store.request(photo, in: folder)
        try await eventually { store.cached(photo, deviceID: "p1") != nil }
        #expect(device.thumbnailCalls == 2)
    }

    @Test func transientFailureIsRetriedAfterBackoff() async throws {
        let photo = device.addFile("a.jpg", data: Data(count: 10))
        device.setThumbnail(Data("thumb".utf8), for: photo.objectID)
        device.failNextThumbnail(with: .deviceBusy)
        let (store, _) = try await makeStore()
        store.request(photo, in: folder)
        try await eventually { device.thumbnailCalls == 1 && store.pendingCount == 0 }
        store.request(photo, in: folder) // inside the back-off window
        try await eventually { store.pendingCount == 0 }
        #expect(device.thumbnailCalls == 1)
        clock.date.addTimeInterval(16)
        store.request(photo, in: folder)
        try await eventually { store.cached(photo, deviceID: "p1") != nil }
        #expect(device.thumbnailCalls == 2)
    }

    @Test func emptyCacheFileIsIgnored() async throws {
        let photo = device.addFile("a.jpg", data: Data(count: 10))
        device.setThumbnail(Data("thumb".utf8), for: photo.objectID)
        let dir = try makeTempDirectory()
        let file = dir.appendingPathComponent(ItemKey(entry: photo, deviceID: "p1").fileName)
        try Data().write(to: file)
        let (store, _) = try await makeStore(directory: dir)
        store.request(photo, in: folder)
        try await eventually { store.cached(photo, deviceID: "p1") != nil }
        #expect(device.thumbnailCalls == 1)
        #expect(try Data(contentsOf: file) == Data("thumb".utf8))
    }

    @Test func changedItemGetsNewThumbnail() async throws {
        let photo = device.addFile("a.jpg", data: Data(count: 10))
        device.setThumbnail(Data("v1".utf8), for: photo.objectID)
        let (store, _) = try await makeStore()
        store.request(photo, in: folder)
        try await eventually { store.cached(photo, deviceID: "p1") != nil }
        var edited = photo
        edited.size = 20
        edited.modified = Date(timeIntervalSince1970: 1_800_000_000)
        device.setThumbnail(Data("v2".utf8), for: photo.objectID)
        store.request(edited, in: folder)
        try await eventually { store.cached(edited, deviceID: "p1") != nil }
        #expect(store.cached(edited, deviceID: "p1") == Data("v2".utf8))
    }

    @Test func onlyImagesAndVideosWantThumbnails() {
        func entry(_ name: String, folder: Bool = false) -> FileEntry {
            FileEntry(objectID: 1, parentID: FileEntry.rootID, storageID: 1, name: name, size: 1, modified: nil, isFolder: folder)
        }
        #expect(ThumbnailStore.wantsThumbnail(entry("IMG_1.JPG")))
        #expect(ThumbnailStore.wantsThumbnail(entry("clip.mp4")))
        #expect(!ThumbnailStore.wantsThumbnail(entry("notes.txt")))
        #expect(!ThumbnailStore.wantsThumbnail(entry("Photos.jpg", folder: true)))
    }

    @Test func memoryLimitEvictsOldestButDiskStillServesThem() async throws {
        let photos = (0..<3).map { device.addFile("p\($0).jpg", data: Data(count: 10)) }
        for photo in photos { device.setThumbnail(Data("t\(photo.objectID)".utf8), for: photo.objectID) }
        provider.attach(device)
        let service = LocalMTPService(provider: provider)
        _ = try await service.devices()
        let store = ThumbnailStore(service: service, directory: try makeTempDirectory(), memoryLimit: 2)
        for photo in photos {
            store.request(photo, in: folder)
            try await eventually { store.pendingCount == 0 }
        }
        #expect(store.cached(photos[0], deviceID: "p1") == nil) // evicted
        #expect(store.cached(photos[2], deviceID: "p1") != nil)
        let calls = device.thumbnailCalls
        store.request(photos[0], in: folder)
        try await eventually { store.cached(photos[0], deviceID: "p1") != nil }
        #expect(device.thumbnailCalls == calls) // came back from disk, not the phone
    }

    @Test func pruneDeletesOldestFilesUntilUnderTheLimit() async throws {
        let dir = try makeTempDirectory()
        let fm = FileManager.default
        for (i, name) in ["old", "middle", "new"].enumerated() {
            let url = dir.appendingPathComponent(name)
            try Data(count: 100).write(to: url)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(1_000 + i))],
                                 ofItemAtPath: url.path)
        }
        await ThumbnailStore.pruneDirectory(dir, toAtMost: 200)
        #expect(try fm.contentsOfDirectory(atPath: dir.path).sorted() == ["middle", "new"])
        await ThumbnailStore.pruneDirectory(dir, toAtMost: 1_000) // already under: nothing removed
        #expect(try fm.contentsOfDirectory(atPath: dir.path).count == 2)
    }
}
