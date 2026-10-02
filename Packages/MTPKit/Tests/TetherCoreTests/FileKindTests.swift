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
        let expected = FileKind.sentenceCase(UTType.folder.localizedDescription ?? String(localized: "Folder", bundle: .module))
        #expect(FileKind.description(for: entry("DCIM", folder: true)) == expected)
        #expect(FileKind.description(for: entry("DCIM", folder: true)).first?.isUppercase == true)
    }

    @Test func knownExtensionUsesTheSystemDescription() {
        #expect(FileKind.description(for: entry("IMG_0001.jpg")) == FileKind.sentenceCase(UTType.jpeg.localizedDescription!))
        #expect(FileKind.description(for: entry("notes.TXT")) == FileKind.sentenceCase(UTType.plainText.localizedDescription!))
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

@Suite struct FileKindSentenceCaseTests {
    @Test func capitalizesALowercaseFirstWord() {
        #expect(FileKind.sentenceCase("папка") == "Папка")
        #expect(FileKind.sentenceCase("текст") == "Текст")
        #expect(FileKind.sentenceCase("изображение JPEG") == "Изображение JPEG")
    }

    @Test func leavesWordsThatAlreadyHaveCapitalsAlone() {
        #expect(FileKind.sentenceCase("JPEG image") == "JPEG image")
        #expect(FileKind.sentenceCase("iCalendar file") == "iCalendar file")
        #expect(FileKind.sentenceCase("Folder") == "Folder")
    }

    @Test func handlesEmptyAndNonLetters() {
        #expect(FileKind.sentenceCase("") == "")
        #expect(FileKind.sentenceCase("3D model") == "3D model")
    }
}
