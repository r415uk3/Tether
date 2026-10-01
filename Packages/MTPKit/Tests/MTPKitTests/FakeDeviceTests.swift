import Foundation
import Testing
@testable import MTPKit

@Test func listsChildrenOfRootAndFolders() throws {
    let device = FakeDevice()
    let dcim = device.addFolder("DCIM")
    device.addFile("a.jpg", data: Data(count: 10), in: dcim.objectID)
    device.addFile("notes.txt", data: Data("x".utf8))
    let root = try device.listFolder(storageID: 1, folderID: FileEntry.rootID)
    #expect(root.map(\.name) == ["DCIM", "notes.txt"])
    #expect(try device.listFolder(storageID: 1, folderID: dcim.objectID).map(\.name) == ["a.jpg"])
}

@Test func failFaultAppliesToNextOperationOnly() throws {
    let device = FakeDevice()
    device.inject(.fail(.deviceBusy))
    #expect(throws: MTPError.deviceBusy) { try device.storages() }
    #expect(try device.storages().count == 1)
}

@Test func disconnectIsPermanent() throws {
    let device = FakeDevice()
    device.inject(.disconnectAfter(bytes: 0))
    #expect(throws: MTPError.deviceDisconnected) { try device.storages() }
    #expect(throws: MTPError.deviceDisconnected) { try device.storages() }
}

@Test func cancelledUploadLeavesPartialObject() throws {
    let device = FakeDevice(chunkSize: 4)
    let dir = try makeTempDirectory()
    let file = dir.appendingPathComponent("big.bin")
    try Data(count: 40).write(to: file)
    #expect(throws: MTPError.cancelled) {
        try device.upload(from: file, name: "big.bin", size: 40, storageID: 1,
                          parentID: FileEntry.rootID) { done, _ in done < 8 }
    }
    let partial = try #require(device.children(of: FileEntry.rootID).first)
    #expect(partial.name == "big.bin")
    #expect(device.data(of: partial.objectID)!.count < 40)
}

@Test func deletingFolderRemovesSubtree() throws {
    let device = FakeDevice()
    let a = device.addFolder("A")
    let b = device.addFolder("B", in: a.objectID)
    device.addFile("x", data: Data(count: 1), in: b.objectID)
    try device.delete(objectID: a.objectID)
    #expect(device.children(of: FileEntry.rootID).isEmpty)
    #expect(device.children(of: b.objectID).isEmpty)
}

@Test func providerReportsAttachedAndOpens() throws {
    let provider = FakeDeviceProvider()
    provider.attach(FakeDevice(id: "p1"))
    provider.attachUnavailable(AttachedDevice(id: "p2", manufacturer: "Samsung", model: "S25"), error: .deviceLocked)
    #expect(provider.attachedDevices().map(\.id) == ["p1", "p2"])
    #expect(try provider.open(provider.attachedDevices()[0]).info.id == "p1")
    #expect(throws: MTPError.deviceLocked) { try provider.open(provider.attachedDevices()[1]) }
    #expect(provider.openCount("p1") == 1)
    provider.detach("p1")
    #expect(provider.attachedDevices().map(\.id) == ["p2"])
}
