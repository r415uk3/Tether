import Foundation
import Testing
@testable import MTPKit

@Suite struct DownloadTests {
    let device = FakeDevice(chunkSize: 4096)

    @Test func downloadsFileAtomically() throws {
        let file = device.addFile("a.txt", data: Data("hello".utf8))
        let dir = try makeTempDirectory()
        let url = try Transfers.download(file, from: device, into: dir) { _, _ in true }
        #expect(url.lastPathComponent == "a.txt")
        #expect(try Data(contentsOf: url) == Data("hello".utf8))
        #expect(try contents(of: dir) == ["a.txt"])
    }

    @Test func verifiesEntryBeforeDownloading() throws {
        let folder = device.addFolder("Docs")
        let nested = device.addFile("n.txt", data: Data("n".utf8), in: folder.objectID)
        let dir = try makeTempDirectory()
        _ = try Transfers.download(folder, from: device, into: dir) { _, _ in true }
        let url = try Transfers.download(nested, from: device, into: dir) { _, _ in true }
        #expect(try Data(contentsOf: url) == Data("n".utf8))
        #expect(try contents(of: dir) == ["Docs", "n.txt"])
    }

    /// After a replug the phone may reuse handles for different objects; a stale entry must not download them.
    @Test func staleEntryIsNotFound() throws {
        let file = device.addFile("a.txt", data: Data("hello".utf8))
        let folder = device.addFolder("Docs")
        let dir = try makeTempDirectory()
        var renamed = file
        renamed.name = "other.txt"
        var resized = file
        resized.size = 99
        var asFile = folder
        asFile.isFolder = false
        let missing = FileEntry(objectID: 999, parentID: FileEntry.rootID, storageID: 1, name: "a.txt", size: 5,
                                modified: nil, isFolder: false)
        for stale in [renamed, resized, asFile, missing] {
            #expect(throws: MTPError.notFound) {
                try Transfers.download(stale, from: self.device, into: dir) { _, _ in true }
            }
        }
        #expect(try contents(of: dir).isEmpty)
    }

    @Test func keepsExistingFiles() throws {
        let file = device.addFile("a.txt", data: Data("new".utf8))
        let dir = try makeTempDirectory()
        try Data("old".utf8).write(to: dir.appendingPathComponent("a.txt"))
        let url = try Transfers.download(file, from: device, into: dir) { _, _ in true }
        #expect(url.lastPathComponent == "a 2.txt")
        #expect(try Data(contentsOf: dir.appendingPathComponent("a.txt")) == Data("old".utf8))
    }

    @Test func avoidsNamesOfInProgressDownloads() throws {
        let dir = try makeTempDirectory()
        try Data().write(to: dir.appendingPathComponent("a.txt.partial"))
        #expect(Transfers.uniqueURL(for: "a.txt", in: dir).lastPathComponent == "a 2.txt")
    }

    @Test func uniqueNameHandlesExtensionsAndFolders() {
        let taken: Set<String> = ["a.txt", "a 2.txt", "Photos", ".bashrc"]
        #expect(Transfers.uniqueName(for: "a.txt") { taken.contains($0) } == "a 3.txt")
        #expect(Transfers.uniqueName(for: "Photos") { taken.contains($0) } == "Photos 2")
        #expect(Transfers.uniqueName(for: ".bashrc") { taken.contains($0) } == ".bashrc 2")
        #expect(Transfers.uniqueName(for: "free.txt") { taken.contains($0) } == "free.txt")
    }

    @Test func folderWalkReportsKeepAliveProgress() throws {
        let top = device.addFolder("DCIM")
        let sub = device.addFolder("Camera", in: top.objectID)
        let deep = device.addFolder("2026", in: sub.objectID)
        device.addFile("a.bin", data: Data(count: 8192), in: deep.objectID)
        let dir = try makeTempDirectory()
        var calls: [(UInt64, UInt64)] = []
        _ = try Transfers.download(top, from: device, into: dir) { done, total in
            calls.append((done, total))
            return true
        }
        // One call per listed folder (3) happens before any file byte is reported (done > 0).
        let beforeBytes = calls.prefix { $0.0 == 0 }.count
        #expect(beforeBytes >= 3)
    }

    @Test func cancelDuringFolderWalkLeavesNothing() throws {
        let top = device.addFolder("DCIM")
        let sub = device.addFolder("Camera", in: top.objectID)
        device.addFile("a.bin", data: Data(count: 8192), in: sub.objectID)
        let dir = try makeTempDirectory()
        #expect(throws: MTPError.cancelled) {
            try Transfers.download(top, from: device, into: dir) { _, _ in false }
        }
        #expect(try contents(of: dir).isEmpty)
    }

    @Test func cancelRemovesPartial() throws {
        let file = device.addFile("big.bin", data: Data(count: 40_960))
        let dir = try makeTempDirectory()
        #expect(throws: MTPError.cancelled) {
            try Transfers.download(file, from: device, into: dir) { done, _ in done < 8192 }
        }
        #expect(try contents(of: dir).isEmpty)
    }

    @Test func disconnectRemovesPartial() throws {
        let file = device.addFile("big.bin", data: Data(count: 40_960))
        device.inject(.disconnectAfter(bytes: 8192))
        let dir = try makeTempDirectory()
        #expect(throws: MTPError.deviceDisconnected) {
            try Transfers.download(file, from: device, into: dir) { _, _ in true }
        }
        #expect(try contents(of: dir).isEmpty)
    }

    @Test func downloadsFolderTreeWithCumulativeProgress() throws {
        let dcim = device.addFolder("DCIM")
        let camera = device.addFolder("Camera", in: dcim.objectID)
        device.addFile("x.jpg", data: Data(count: 5000), in: camera.objectID)
        device.addFile("y.txt", data: Data(count: 3000), in: dcim.objectID)
        let dir = try makeTempDirectory()
        let last = Log<(UInt64, UInt64)>()
        let url = try Transfers.download(dcim, from: device, into: dir) { done, total in last.append((done, total)); return true }
        #expect(url.lastPathComponent == "DCIM")
        #expect(try Data(contentsOf: url.appendingPathComponent("Camera/x.jpg")).count == 5000)
        #expect(try Data(contentsOf: url.appendingPathComponent("y.txt")).count == 3000)
        #expect(last.items.last! == (8000, 8000))
        #expect(try contents(of: dir) == ["DCIM"])
    }

    @Test func sanitizesUnsafeNames() throws {
        let dir = try makeTempDirectory()
        let evil = device.addFile("../evil.txt", data: Data("e".utf8))
        let slashed = device.addFile("a/b.txt", data: Data("s".utf8))
        let dots = device.addFolder("..")
        device.addFile("inner.txt", data: Data("i".utf8), in: dots.objectID)
        for entry in [evil, slashed, dots] {
            _ = try Transfers.download(entry, from: device, into: dir) { _, _ in true }
        }
        #expect(try contents(of: dir) == ["..-evil.txt", "_", "a-b.txt"])
        #expect(try contents(of: dir.appendingPathComponent("_")) == ["inner.txt"])
        #expect(Transfers.safeName("") == "_")
        #expect(Transfers.safeName(".") == "_")
    }

    @Test func keepsCollidingSiblingsInFolder() throws {
        let folder = device.addFolder("Dup")
        device.addFile("IMG.jpg", data: Data("1".utf8), in: folder.objectID)
        device.addFile("IMG.jpg", data: Data("2".utf8), in: folder.objectID)
        device.addFile("a/b.txt", data: Data("3".utf8), in: folder.objectID)
        device.addFile("a-b.txt", data: Data("4".utf8), in: folder.objectID)
        device.addFile("A.txt", data: Data("5".utf8), in: folder.objectID)
        device.addFile("a.txt", data: Data("6".utf8), in: folder.objectID)
        let dir = try makeTempDirectory()
        let url = try Transfers.download(folder, from: device, into: dir) { _, _ in true }
        let names = try contents(of: url)
        #expect(names.count == 6)
        #expect(Set(names.map { $0.lowercased() }).count == 6)
        let all = try names.map { String(decoding: try Data(contentsOf: url.appendingPathComponent($0)), as: UTF8.self) }
        #expect(Set(all) == ["1", "2", "3", "4", "5", "6"])
        #expect(names.contains("IMG.jpg") && names.contains("IMG 2.jpg"))
    }

    @Test func folderCancelRemovesPartialTree() throws {
        let folder = device.addFolder("Big")
        device.addFile("x.bin", data: Data(count: 20_000), in: folder.objectID)
        device.addFile("y.bin", data: Data(count: 20_000), in: folder.objectID)
        let dir = try makeTempDirectory()
        #expect(throws: MTPError.cancelled) {
            try Transfers.download(folder, from: device, into: dir) { done, _ in done < 25_000 }
        }
        #expect(try contents(of: dir).isEmpty)
    }

    @Test func folderDisconnectRemovesPartialTree() throws {
        let folder = device.addFolder("Big")
        device.addFile("x.bin", data: Data(count: 20_000), in: folder.objectID)
        device.addFile("y.bin", data: Data(count: 20_000), in: folder.objectID)
        let dir = try makeTempDirectory()
        let progress = Log<UInt64>()
        // The fault is injected once the first file is moving, so it hits a file transfer (not the folder
        // listing) after the partial tree already exists on disk.
        #expect(throws: MTPError.deviceDisconnected) {
            try Transfers.download(folder, from: device, into: dir) { done, _ in
                if progress.items.isEmpty { device.inject(.disconnectAfter(bytes: 1)) }
                progress.append(done)
                return true
            }
        }
        #expect(!progress.items.isEmpty)
        #expect(try contents(of: dir).isEmpty)
    }

    @Test func staleParentIDFailsWithoutListing() throws {
        let camera = device.addFolder("Camera")
        let file = device.addFile("a.jpg", data: Data(count: 10))
        var stale = file
        stale.parentID = camera.objectID
        try expectRejectedWithoutSideEffects(stale)
    }

    @Test func staleSizeFailsWithoutListing() throws {
        let file = device.addFile("a.jpg", data: Data(count: 10))
        var stale = file
        stale.size = 11
        try expectRejectedWithoutSideEffects(stale)
    }

    @Test func staleIsFolderFailsWithoutListing() throws {
        let file = device.addFile("a.jpg", data: Data(count: 10))
        var stale = file
        stale.isFolder = true
        try expectRejectedWithoutSideEffects(stale)
    }

    private func expectRejectedWithoutSideEffects(_ stale: FileEntry) throws {
        let dir = try makeTempDirectory()
        let before = device.listFolderCalls
        #expect(throws: MTPError.notFound) {
            try Transfers.download(stale, from: device, into: dir) { _, _ in true }
        }
        #expect(device.listFolderCalls == before)
        #expect(try contents(of: dir).isEmpty)
    }

    @Test func existingFolderNameGetsSuffix() throws {
        let folder = device.addFolder("Photos")
        device.addFile("p.jpg", data: Data("p".utf8), in: folder.objectID)
        let dir = try makeTempDirectory()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Photos"), withIntermediateDirectories: false)
        let url = try Transfers.download(folder, from: device, into: dir) { _, _ in true }
        #expect(url.lastPathComponent == "Photos 2")
        #expect(try contents(of: url) == ["p.jpg"])
        #expect(try contents(of: dir) == ["Photos", "Photos 2"])
    }

    @Test func verificationDoesNotListTheParentFolder() throws {
        let camera = device.addFolder("Camera")
        let file = device.addFile("a.jpg", data: Data(count: 10), in: camera.objectID)
        let before = device.listFolderCalls
        _ = try Transfers.download(file, from: device, into: try makeTempDirectory()) { _, _ in true }
        #expect(device.listFolderCalls == before)
    }

    @Test func mismatchedObjectFailsWithoutListing() throws {
        let file = device.addFile("a.jpg", data: Data(count: 10))
        var stale = file
        stale.name = "other.jpg" // same handle, different object now
        let dir = try makeTempDirectory()
        let before = device.listFolderCalls
        #expect(throws: MTPError.notFound) {
            try Transfers.download(stale, from: device, into: dir) { _, _ in true }
        }
        #expect(device.listFolderCalls == before)
        #expect(try contents(of: dir).isEmpty)
    }

    @Test func injectedFaultReachesTheTransferAndPartialIsRemoved() throws {
        let file = device.addFile("big.bin", data: Data(count: 40_960))
        device.inject(.disconnectAfter(bytes: 8192))
        let dir = try makeTempDirectory()
        let progress = Log<UInt64>()
        #expect(throws: MTPError.deviceDisconnected) {
            try Transfers.download(file, from: device, into: dir) { done, _ in progress.append(done); return true }
        }
        #expect(!progress.items.isEmpty) // bytes moved before the fault: the transfer really started
        #expect(try contents(of: dir).isEmpty)
    }
}
