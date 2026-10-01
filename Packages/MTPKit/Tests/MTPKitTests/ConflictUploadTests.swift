import Foundation
import Testing
@testable import MTPKit

@Suite struct ConflictUploadTests {
    let root = FileEntry.rootID

    private func makeFile(_ name: String, _ text: String) throws -> URL {
        let url = try makeTempDirectory().appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func failPolicyStillRejects() throws {
        let device = FakeDevice()
        device.addFile("photo.jpg", data: Data("old".utf8))
        #expect(throws: MTPError.nameConflict("photo.jpg")) {
            try Transfers.upload(try makeFile("photo.jpg", "new"), to: device, storageID: 1, parentID: root,
                                 conflict: .fail) { _, _ in true }
        }
    }

    @Test func policyIsIgnoredWithoutAClash() throws {
        let device = FakeDevice()
        let a = try Transfers.upload(try makeFile("a.txt", "a"), to: device, storageID: 1, parentID: root,
                                     conflict: .replace) { _, _ in true }
        let b = try Transfers.upload(try makeFile("b.txt", "b"), to: device, storageID: 1, parentID: root,
                                     conflict: .keepBoth) { _, _ in true }
        #expect([a.name, b.name] == ["a.txt", "b.txt"])
        #expect(device.children(of: root).map(\.name) == ["a.txt", "b.txt"])
    }

    @Test func keepBothUploadsUnderNextFreeName() throws {
        let device = FakeDevice()
        device.addFile("photo.jpg", data: Data("old".utf8))
        device.addFile("photo 2.jpg", data: Data("older".utf8))
        let entry = try Transfers.upload(try makeFile("photo.jpg", "new"), to: device, storageID: 1, parentID: root,
                                         conflict: .keepBoth) { _, _ in true }
        #expect(entry.name == "photo 3.jpg")
        #expect(device.children(of: root).map(\.name).sorted() == ["photo 2.jpg", "photo 3.jpg", "photo.jpg"])
        #expect(device.data(of: entry.objectID) == Data("new".utf8))
    }

    @Test func replaceLeavesOneItemWithNewContents() throws {
        let device = FakeDevice()
        device.addFile("photo.jpg", data: Data("old".utf8))
        let entry = try Transfers.upload(try makeFile("photo.jpg", "new"), to: device, storageID: 1, parentID: root,
                                         conflict: .replace) { _, _ in true }
        let children = device.children(of: root)
        #expect(children.map(\.name) == ["photo.jpg"])
        #expect(entry.name == "photo.jpg")
        #expect(entry.objectID == children[0].objectID)
        #expect(device.data(of: children[0].objectID) == Data("new".utf8))
    }

    @Test func cancelledReplaceKeepsOriginal() throws {
        let device = FakeDevice(chunkSize: 4)
        let original = device.addFile("photo.jpg", data: Data("old".utf8))
        let url = try makeFile("photo.jpg", String(repeating: "n", count: 40))
        #expect(throws: MTPError.cancelled) {
            try Transfers.upload(url, to: device, storageID: 1, parentID: root, conflict: .replace) { done, _ in done < 8 }
        }
        #expect(device.children(of: root).map(\.objectID) == [original.objectID])
        #expect(device.data(of: original.objectID) == Data("old".utf8))
    }

    @Test func replaceFolderSwapsWholeTree() throws {
        let device = FakeDevice()
        let oldAlbum = device.addFolder("Album")
        device.addFile("old.jpg", data: Data(count: 3), in: oldAlbum.objectID)
        let dir = try makeTempDirectory()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Album"), withIntermediateDirectories: true)
        try Data(count: 5).write(to: dir.appendingPathComponent("Album/new.jpg"))
        let album = try Transfers.upload(dir.appendingPathComponent("Album"), to: device, storageID: 1, parentID: root,
                                         conflict: .replace) { _, _ in true }
        #expect(device.children(of: root).map(\.name) == ["Album"])
        #expect(device.children(of: album.objectID).map(\.name) == ["new.jpg"])
    }
}
