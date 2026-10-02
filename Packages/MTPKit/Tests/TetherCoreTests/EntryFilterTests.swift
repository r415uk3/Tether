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

    private func entry(_ name: String, id: UInt32) -> FileEntry {
        FileEntry(objectID: id, parentID: FileEntry.rootID, storageID: 1, name: name,
                  size: 0, modified: nil, isFolder: false)
    }

    @Test func searchIgnoresCaseAndDiacritics() {
        let entries = ["Фото.JPG", "Café.png", "notes.txt"].enumerated().map { entry($0.element, id: UInt32($0.offset)) }
        #expect(EntryFilter.matching(entries, query: "фото").map(\.name) == ["Фото.JPG"])
        #expect(EntryFilter.matching(entries, query: "cafe").map(\.name) == ["Café.png"])
        #expect(EntryFilter.matching(entries, query: "  NOTES ").map(\.name) == ["notes.txt"])
    }

    @Test func blankQueryShowsAll() {
        let entries = [entry("a", id: 1), entry("b", id: 2)]
        #expect(EntryFilter.matching(entries, query: "").count == 2)
        #expect(EntryFilter.matching(entries, query: "   ").count == 2)
    }

    @Test func isSearchingIgnoresWhitespaceAndNewlines() {
        #expect(!EntryFilter.isSearching(""))
        #expect(!EntryFilter.isSearching(" \n\t "))
        #expect(EntryFilter.isSearching(" a\n"))
        #expect(EntryFilter.matching([entry("a", id: 1), entry("b", id: 2)], query: "\n").count == 2)
    }

    @Test func searchMatchesAnywhereInTheName() {
        let entries = [entry("IMG_0012.jpg", id: 1), entry("Download", id: 2)]
        #expect(EntryFilter.matching(entries, query: "0012").map(\.name) == ["IMG_0012.jpg"])
    }
}
