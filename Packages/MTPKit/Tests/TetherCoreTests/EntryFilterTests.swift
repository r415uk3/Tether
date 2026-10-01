import Foundation
import Testing
import MTPKit
@testable import TetherCore

@MainActor
@Suite struct EntryFilterTests {
    private func entry(_ name: String) -> FileEntry {
        FileEntry(objectID: UInt32(name.hashValue & 0xFFFF), parentID: FileEntry.rootID, storageID: 1, name: name,
                  size: 0, modified: nil, isFolder: false)
    }

    @Test func hiddenEntriesAreFilteredButStillClash() async {
        let entries = [entry(".nomedia"), entry("a.jpg")]
        #expect(EntryFilter.visible(entries, showHidden: false).map(\.name) == ["a.jpg"])
        #expect(EntryFilter.visible(entries, showHidden: true).map(\.name) == [".nomedia", "a.jpg"])
        // The browser passes ALL names (hidden included) to the planner, so a hidden clash is still asked about.
        var asked = false
        _ = await UploadPlanner.plan([URL(fileURLWithPath: "/m/.nomedia")], existingNames: Set(entries.map(\.name)),
                                     defaultChoice: nil) { _ in asked = true; return .init(choice: .skip, applyToAll: false) }
        #expect(asked)
    }
}
