import Foundation
import MTPKit

public enum EntryFilter {
    /// Hides dot-files unless `showHidden` (Android uses them for ".nomedia", ".thumbnails", …).
    public static func visible(_ entries: [FileEntry], showHidden: Bool) -> [FileEntry] {
        showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
    }

    /// Entries whose name contains `query`, ignoring case and diacritics, in the user's locale. A blank query matches all.
    public static func matching(_ entries: [FileEntry], query: String) -> [FileEntry] {
        let needle = trimmed(query)
        guard !needle.isEmpty else { return entries }
        return entries.filter { $0.name.localizedStandardContains(needle) }
    }

    /// True when `query` filters anything, i.e. `matching` would not return every entry.
    public static func isSearching(_ query: String) -> Bool {
        !trimmed(query).isEmpty
    }

    private static func trimmed(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
