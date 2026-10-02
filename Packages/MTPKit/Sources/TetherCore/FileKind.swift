import Foundation
import MTPKit
import UniformTypeIdentifiers

/// The "Kind" column text: the system's localized type description, like Finder.
public enum FileKind {
    public static func description(for entry: FileEntry) -> String {
        if entry.isFolder { return UTType.folder.localizedDescription ?? String(localized: "Folder", bundle: .module) }
        let ext = (entry.name as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic, let text = type.localizedDescription {
            return text
        }
        return String(localized: "Document", bundle: .module)
    }
}
