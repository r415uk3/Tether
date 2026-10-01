import Foundation
import Testing
import MTPKit
@testable import TetherCore

@Suite struct NameValidationTests {
    private func entry(_ name: String, _ id: UInt32) -> FileEntry {
        FileEntry(objectID: id, parentID: FileEntry.rootID, storageID: 1, name: name, size: 0, modified: nil, isFolder: false)
    }
    private var siblings: [FileEntry] { [entry("a.txt", 1), entry("b.txt", 2)] }

    @Test func acceptsANewName() {
        #expect(NameValidation.validate("  c.txt \n", current: "a.txt", siblings: siblings) == .valid("c.txt"))
    }

    @Test func sameNameIsUnchanged() {
        #expect(NameValidation.validate("a.txt", current: "a.txt", siblings: siblings) == .unchanged)
    }

    @Test func caseOnlyRenameIsAllowed() {
        #expect(NameValidation.validate("A.txt", current: "a.txt", siblings: siblings) == .valid("A.txt"))
    }

    @Test func rejectsTakenEmptyAndInvalidNames() {
        #expect(NameValidation.validate("b.txt", current: "a.txt", siblings: siblings) == .invalid(.taken("b.txt")))
        #expect(NameValidation.validate("   ", current: "a.txt", siblings: siblings) == .invalid(.empty))
        #expect(NameValidation.validate("x/y", current: "a.txt", siblings: siblings) == .invalid(.invalidCharacters))
        #expect(NameValidation.validate("..", current: "a.txt", siblings: siblings) == .invalid(.invalidCharacters))
        #expect(NameValidation.validate(".", current: "a.txt", siblings: siblings) == .invalid(.invalidCharacters))
    }

    @Test func problemsHaveMessages() {
        for problem in [NameProblem.empty, .invalidCharacters, .taken("b.txt")] { #expect(!problem.message.isEmpty) }
        #expect(NameProblem.taken("b.txt").message.contains("b.txt"))
    }

    @Test func newFolderNameIsUnique() {
        let base = String(localized: "untitled folder")
        #expect(NameValidation.newFolderName(siblings: siblings) == base)
        #expect(NameValidation.newFolderName(siblings: siblings + [entry(base, 3)]) == "\(base) 2")
    }
}
