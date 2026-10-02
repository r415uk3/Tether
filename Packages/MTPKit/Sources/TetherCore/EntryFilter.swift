import Foundation
import MTPKit

public enum EntryFilter {
    /// Hides dot-files unless `showHidden` (Android uses them for ".nomedia", ".thumbnails", …).
    public static func visible(_ entries: [FileEntry], showHidden: Bool) -> [FileEntry] {
        showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
    }

    /// Entries whose name contains `query`, ignoring case and diacritics, in the user's locale. A blank query matches all.
    public static func matching(_ entries: [FileEntry], query: String) -> [FileEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter { $0.name.localizedStandardContains(needle) }
    }
}
