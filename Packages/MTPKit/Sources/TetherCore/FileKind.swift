import Foundation
import MTPKit
import UniformTypeIdentifiers

/// The "Kind" column text: the system's localized type description, like Finder.
public enum FileKind {
    public static func description(for entry: FileEntry) -> String {
        if entry.isFolder { return sentenceCase(UTType.folder.localizedDescription ?? String(localized: "Folder", bundle: .module)) }
        let ext = (entry.name as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic, let text = type.localizedDescription {
            return sentenceCase(text)
        }
        return String(localized: "Document", bundle: .module)
    }

    /// Some localizations (e.g. Russian «папка», «текст») return lowercase descriptions; Finder shows them
    /// capitalized. Capitalizes the first letter only when the first word has no capitals of its own,
    /// so names like "iCalendar file" or "JPEG image" stay untouched.
    static func sentenceCase(_ text: String) -> String {
        guard let first = text.first, first.isLetter, first.isLowercase else { return text }
        let firstWord = text.prefix { !$0.isWhitespace }
        guard !firstWord.contains(where: \.isUppercase) else { return text }
        return String(first).uppercased(with: .current) + text.dropFirst()
    }
}
