import Foundation
import Testing
@testable import MTPKit

@Suite struct UploadTests {
    let root = FileEntry.rootID

    private func makeFile(_ name: String, bytes: Int, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
        return url
    }

    @Test func uploadsFileWithProgress() throws {
        let device = FakeDevice(chunkSize: 1000)
        let file = try makeFile("photo.jpg", bytes: 10_000, in: try makeTempDirectory())
        let last = Log<(UInt64, UInt64)>()
        let entry = try Transfers.upload(file, to: device, storageID: 1, parentID: root) { d, t in last.append((d, t)); return true }
        #expect(entry.name == "photo.jpg")
        #expect(device.data(of: entry.objectID) == (try Data(contentsOf: file)))
        #expect(last.items.last! == (10_000, 10_000))
    }

    @Test func uploadsFolderTreeSkippingHiddenFiles() throws {
        let device = FakeDevice()
        let dir = try makeTempDirectory()
        _ = try makeFile("Album/a.jpg", bytes: 100, in: dir)
        _ = try makeFile("Album/sub/b.jpg", bytes: 200, in: dir)
        _ = try makeFile("Album/.DS_Store", bytes: 10, in: dir)
        let album = try Transfers.upload(dir.appendingPathComponent("Album"), to: device, storageID: 1, parentID: root) { _, _ in true }
        #expect(album.isFolder)
        let children = device.children(of: album.objectID)
        #expect(children.map(\.name).sorted() == ["a.jpg", "sub"])
        let sub = try #require(children.first { $0.name == "sub" })
        #expect(device.children(of: sub.objectID).map(\.name) == ["b.jpg"])
    }

    @Test func folderUploadReportsProgressAfterEachFolder() throws {
        let device = FakeDevice()
        let dir = try makeTempDirectory()
        _ = try makeFile("Album/sub/deep/b.jpg", bytes: 200, in: dir)
        var calls = 0
        _ = try Transfers.upload(dir.appendingPathComponent("Album"), to: device, storageID: 1, parentID: root) { done, _ in
            if done == 0 { calls += 1 }
            return true
        }
        #expect(calls >= 3) // Album, sub, deep
    }

    @Test func cancelDuringFolderCreationDeletesPartialFolder() throws {
        let device = FakeDevice()
        let dir = try makeTempDirectory()
        _ = try makeFile("Album/sub/b.jpg", bytes: 200, in: dir)
        var calls = 0
        #expect(throws: MTPError.cancelled) {
            try Transfers.upload(dir.appendingPathComponent("Album"), to: device, storageID: 1, parentID: root) { _, _ in
                calls += 1
                return calls < 2 // cancel after the second folder is created
            }
        }
        #expect(device.children(of: root).isEmpty)
    }

    @Test func rejectsWhenStorageFull() throws {
        let device = FakeDevice(storages: [StorageInfo(id: 1, name: "S", capacity: 10_000, freeSpace: 1000)])
        let file = try makeFile("a.bin", bytes: 2000, in: try makeTempDirectory())
        #expect(throws: MTPError.storageFull(needed: 2000, available: 1000)) {
            try Transfers.upload(file, to: device, storageID: 1, parentID: root) { _, _ in true }
        }
        #expect(device.children(of: root).isEmpty)
    }

    @Test func rejectsFiveGigabyteFileWhenFourAreFree() throws {
        let device = FakeDevice(storages: [StorageInfo(id: 1, name: "S", capacity: 8_000_000_000, freeSpace: 4_000_000_000)])
        let url = try makeTempDirectory().appendingPathComponent("movie.mkv")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 5_368_709_120) // sparse: instant, no disk use
        try handle.close()
        #expect(throws: MTPError.storageFull(needed: 5_368_709_120, available: 4_000_000_000)) {
            try Transfers.upload(url, to: device, storageID: 1, parentID: root) { _, _ in true }
        }
    }

    @Test func rejectsNameConflict() throws {
        let device = FakeDevice()
        device.addFile("photo.jpg", data: Data(count: 1))
        let file = try makeFile("photo.jpg", bytes: 10, in: try makeTempDirectory())
        #expect(throws: MTPError.nameConflict("photo.jpg")) {
            try Transfers.upload(file, to: device, storageID: 1, parentID: root) { _, _ in true }
        }
        #expect(device.children(of: root).count == 1)
    }

    @Test func cancelDeletesPartialObject() throws {
        let device = FakeDevice(chunkSize: 4096)
        let file = try makeFile("big.bin", bytes: 40_960, in: try makeTempDirectory())
        #expect(throws: MTPError.cancelled) {
            try Transfers.upload(file, to: device, storageID: 1, parentID: root) { done, _ in done < 8192 }
        }
        #expect(device.children(of: root).isEmpty)
    }

    @Test func cancelDuringFolderUploadDeletesFolder() throws {
        let device = FakeDevice(chunkSize: 100)
        let dir = try makeTempDirectory()
        _ = try makeFile("Album/a.jpg", bytes: 1000, in: dir)
        _ = try makeFile("Album/b.jpg", bytes: 1000, in: dir)
        #expect(throws: MTPError.cancelled) {
            try Transfers.upload(dir.appendingPathComponent("Album"), to: device, storageID: 1, parentID: root) { done, _ in done < 1500 }
        }
        #expect(device.children(of: root).isEmpty)
    }

    @Test func freeSpaceIsCheckedForWholeTree() throws {
        let device = FakeDevice(storages: [StorageInfo(id: 1, name: "S", capacity: 10_000, freeSpace: 250)])
        let dir = try makeTempDirectory()
        _ = try makeFile("Album/a.jpg", bytes: 200, in: dir)
        _ = try makeFile("Album/b.jpg", bytes: 200, in: dir)
        #expect(throws: MTPError.storageFull(needed: 400, available: 250)) {
            try Transfers.upload(dir.appendingPathComponent("Album"), to: device, storageID: 1, parentID: root) { _, _ in true }
        }
        #expect(device.children(of: root).isEmpty)
    }

    @Test func skipsSymbolicLinksInsideFolder() throws {
        let device = FakeDevice()
        let outside = try makeTempDirectory()
        _ = try makeFile("x.txt", bytes: 50, in: outside)
        _ = try makeFile("deep/y.txt", bytes: 60, in: outside)
        let dir = try makeTempDirectory()
        _ = try makeFile("Album/real.jpg", bytes: 100, in: dir)
        _ = try makeFile("Album/sub/inner.jpg", bytes: 100, in: dir)
        let fm = FileManager.default
        try fm.createSymbolicLink(at: dir.appendingPathComponent("Album/sub/link.txt"),
                                  withDestinationURL: outside.appendingPathComponent("x.txt"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("Album/dirlink"),
                                  withDestinationURL: outside.appendingPathComponent("deep"))
        let album = try Transfers.upload(dir.appendingPathComponent("Album"), to: device, storageID: 1, parentID: root) { _, _ in true }
        let children = device.children(of: album.objectID)
        #expect(children.map(\.name).sorted() == ["real.jpg", "sub"])
        let sub = try #require(children.first { $0.name == "sub" })
        #expect(device.children(of: sub.objectID).map(\.name) == ["inner.jpg"])
    }

    @Test func progressIsCumulativeAcrossFiles() throws {
        let device = FakeDevice(chunkSize: 100)
        let dir = try makeTempDirectory()
        _ = try makeFile("Album/a.jpg", bytes: 1000, in: dir)
        _ = try makeFile("Album/b.jpg", bytes: 700, in: dir)
        let log = Log<(UInt64, UInt64)>()
        _ = try Transfers.upload(dir.appendingPathComponent("Album"), to: device, storageID: 1, parentID: root) { d, t in log.append((d, t)); return true }
        let dones = log.items.map(\.0)
        #expect(dones == dones.sorted())
        #expect(log.items.allSatisfy { $0.1 == 1700 })
        #expect(log.items.last! == (1700, 1700))
    }
}
