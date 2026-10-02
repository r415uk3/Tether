import Foundation
import Testing
import UniformTypeIdentifiers
import MTPKit
@testable import TetherCore

@Suite struct FileKindTests {
    private func entry(_ name: String, folder: Bool = false) -> FileEntry {
        FileEntry(objectID: 1, parentID: FileEntry.rootID, storageID: 1, name: name, size: 1, modified: nil, isFolder: folder)
    }

    @Test func folderIsFolder() {
        let expected = UTType.folder.localizedDescription ?? String(localized: "Folder", bundle: .module)
        #expect(FileKind.description(for: entry("DCIM", folder: true)) == expected)
    }

    @Test func knownExtensionUsesTheSystemDescription() {
        #expect(FileKind.description(for: entry("IMG_0001.jpg")) == UTType.jpeg.localizedDescription)
        #expect(FileKind.description(for: entry("notes.TXT")) == UTType.plainText.localizedDescription)
    }

    @Test func unknownOrMissingExtensionIsDocument() {
        let document = FileKind.description(for: entry("README"))
        #expect(!document.isEmpty)
        #expect(FileKind.description(for: entry("data.zzqq")) == document)
    }

    @Test func russianDocumentWord() throws {
        let ru = try russianBundle()
        #expect(ru.localizedString(forKey: "Document", value: "?", table: nil) == "Документ")
    }
}
