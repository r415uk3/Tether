import Foundation
import Testing
import MTPKit
@testable import TetherCore

@MainActor
@Suite struct AccessibilityTextTests {
    private func entry(_ name: String, folder: Bool = false, size: UInt64 = 0) -> FileEntry {
        FileEntry(objectID: 1, parentID: FileEntry.rootID, storageID: 1, name: name, size: size, modified: nil, isFolder: folder)
    }

    private func job(_ state: TransferQueue.State, done: UInt64 = 0, total: UInt64 = 0) -> TransferQueue.Job {
        var job = TransferQueue.Job(id: UUID(), kind: .download(entry("clip.mp4", size: total), deviceID: "p1",
                                                                directory: URL(fileURLWithPath: "/tmp")))
        job.state = state
        job.done = done
        job.total = total
        return job
    }

    @Test func folderSaysFolder() {
        #expect(AccessibilityText.file(entry("DCIM", folder: true)) == "DCIM, folder")
    }

    @Test func fileSaysSize() {
        let text = AccessibilityText.file(entry("notes.txt", size: 2_000_000))
        #expect(text.hasPrefix("notes.txt, "))
        #expect(text.contains(ByteCountFormatter.string(fromByteCount: 2_000_000, countStyle: .file)))
    }

    @Test func namesAreLiteral() {
        let name = "50% off %@ “sale”.jpg"
        #expect(AccessibilityText.file(entry(name, size: 1)).hasPrefix(name + ", "))
        #expect(AccessibilityText.file(entry(name, folder: true)).hasPrefix(name + ", "))
    }

    @Test func storageSaysFreeOfTotal() {
        let storage = StorageInfo(id: 1, name: "Internal shared storage", capacity: 128_000_000_000, freeSpace: 12_000_000_000)
        let text = AccessibilityText.storage(storage)
        #expect(text.hasPrefix("Internal shared storage, "))
        #expect(text.contains(ByteCountFormatter.string(fromByteCount: 12_000_000_000, countStyle: .file)))
        #expect(text.contains(ByteCountFormatter.string(fromByteCount: 128_000_000_000, countStyle: .file)))
    }

    @Test func storageWithoutCapacityIsJustTheName() {
        #expect(AccessibilityText.storage(StorageInfo(id: 1, name: "SD card", capacity: 0, freeSpace: 0)) == "SD card")
    }

    @Test func russianFolderWord() {
        let ru = Bundle(url: Bundle.module.url(forResource: "ru", withExtension: "lproj")!)!
        #expect(ru.localizedString(forKey: "%@, folder", value: "?", table: nil) == "%@, папка")
    }

    @Test func queuedJobIsWaiting() {
        #expect(AccessibilityText.transfer(job(.queued)).hasSuffix(", waiting"))
    }

    @Test func runningJobSaysNameAndPercent() {
        let text = AccessibilityText.transfer(job(.running, done: 50, total: 100))
        #expect(text.hasPrefix("clip.mp4, "))
        #expect(text.contains("%"))
    }

    @Test func finishedCancelledAndFailedJobs() {
        #expect(AccessibilityText.transfer(job(.finished(nil))) == "clip.mp4, done")
        #expect(AccessibilityText.transfer(job(.cancelled)) == "clip.mp4, cancelled")
        #expect(AccessibilityText.transfer(job(.failed(.cancelled))).hasPrefix("clip.mp4, failed: "))
    }
}
