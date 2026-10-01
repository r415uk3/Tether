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
        device.inject(.disconnectAfter(bytes: 25_000))
        let dir = try makeTempDirectory()
        #expect(throws: MTPError.deviceDisconnected) {
            try Transfers.download(folder, from: device, into: dir) { _, _ in true }
        }
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
}
