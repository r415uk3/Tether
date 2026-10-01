import MTPKit

public enum EntryFilter {
    /// Hides dot-files unless `showHidden` (Android uses them for ".nomedia", ".thumbnails", …).
    public static func visible(_ entries: [FileEntry], showHidden: Bool) -> [FileEntry] {
        showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
    }
}
