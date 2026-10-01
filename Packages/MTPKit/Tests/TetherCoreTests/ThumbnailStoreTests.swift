import Foundation
import Testing
import MTPKit
@testable import TetherCore

@MainActor
@Suite struct ThumbnailStoreTests {
    let provider = FakeDeviceProvider()
    let device = FakeDevice(id: "p1")
    var folder: FolderRef { FolderRef(deviceID: "p1", storageID: 1) }

    private func makeStore(directory: URL? = nil) async throws -> (ThumbnailStore, LocalMTPService) {
        provider.attach(device)
        let service = LocalMTPService(provider: provider)
        _ = try await service.devices()
        return (ThumbnailStore(service: service, directory: directory), service)
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
        let dir = try makeTempDirectory()
        let (first, service) = try await makeStore(directory: dir)
        first.request(photo, in: folder)
        try await eventually { first.cached(photo, deviceID: "p1") != nil }
        let second = ThumbnailStore(service: service, directory: dir)
        second.request(photo, in: folder)
        try await eventually { second.cached(photo, deviceID: "p1") != nil }
        #expect(device.thumbnailCalls == 1)
    }

    @Test func missingThumbnailIsNotRefetched() async throws {
        let photo = device.addFile("a.jpg", data: Data(count: 10)) // no thumbnail set
        let (store, _) = try await makeStore()
        store.request(photo, in: folder)
        try await eventually { device.thumbnailCalls == 1 }
        try await Task.sleep(for: .milliseconds(50))
        store.request(photo, in: folder)
        try await Task.sleep(for: .milliseconds(50))
        #expect(device.thumbnailCalls == 1)
        #expect(store.cached(photo, deviceID: "p1") == nil)
    }

    @Test func transientFailureIsRetried() async throws {
        let photo = device.addFile("a.jpg", data: Data(count: 10))
        device.setThumbnail(Data("thumb".utf8), for: photo.objectID)
        device.failNextThumbnail(with: .deviceBusy)
        let (store, _) = try await makeStore()
        store.request(photo, in: folder)
        try await eventually { device.thumbnailCalls == 1 }
        try await Task.sleep(for: .milliseconds(50))
        store.request(photo, in: folder)
        try await eventually { store.cached(photo, deviceID: "p1") != nil }
        #expect(device.thumbnailCalls == 2)
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
}
