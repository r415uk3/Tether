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
}
