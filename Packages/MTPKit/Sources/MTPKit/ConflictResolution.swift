import Foundation

/// What an upload does when its destination folder already has an item with the same name.
public enum ConflictResolution: String, Codable, Sendable, CaseIterable {
    /// Refuse with `.nameConflict`. The app asks the user first, so this means the folder changed meanwhile.
    case fail
    /// Keep the existing item; upload as "name 2", "name 3", …
    case keepBoth
    /// Upload under a temporary name, then delete the existing item and rename the new one.
    /// The original is untouched until the new copy has fully arrived.
    case replace
}
