import Foundation
import MTPKit

public enum NameProblem: Error, Equatable, Sendable {
    case empty
    case invalidCharacters
    case taken(String)

    public var message: String {
        switch self {
        case .empty:
            String(localized: "A name can’t be empty.")
        case .invalidCharacters:
            String(localized: "Names can’t contain “/” or be “.” or “..”.")
        case .taken(let name):
            String(localized: "The name “\(name)” is already taken. Please choose a different name.")
        }
    }
}

public enum RenameOutcome: Equatable, Sendable {
    case unchanged
    case valid(String)
    case invalid(NameProblem)
}

public enum NameValidation {
    /// Checks a proposed name for an item called `current` among `siblings` (which may include the item itself).
    /// MTP names are case-sensitive, so a case-only rename is allowed.
    public static func validate(_ proposed: String, current: String, siblings: [FileEntry]) -> RenameOutcome {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .invalid(.empty) }
        if name.contains("/") || name.contains("\0") || name == "." || name == ".." {
            return .invalid(.invalidCharacters)
        }
        if name == current { return .unchanged }
        if siblings.contains(where: { $0.name == name }) { return .invalid(.taken(name)) }
        return .valid(name)
    }

    /// "untitled folder", or "untitled folder 2", … if taken.
    public static func newFolderName(siblings: [FileEntry]) -> String {
        let names = Set(siblings.map(\.name))
        return Transfers.uniqueName(for: String(localized: "untitled folder")) { names.contains($0) }
    }
}
