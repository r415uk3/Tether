import Foundation
import MTPKit

public enum ConflictChoice: Sendable, Equatable {
    case replace, keepBoth, skip
}

public struct ConflictQuestion: Sendable, Equatable {
    public let name: String
    /// Clashes still to come after this one; the prompt offers "Apply to all" when > 0.
    public let remaining: Int

    public init(name: String, remaining: Int) {
        self.name = name
        self.remaining = remaining
    }
}

public struct ConflictAnswer: Sendable, Equatable {
    public let choice: ConflictChoice
    public let applyToAll: Bool

    public init(choice: ConflictChoice, applyToAll: Bool) {
        self.choice = choice
        self.applyToAll = applyToAll
    }
}

public struct PlannedUpload: Sendable, Equatable {
    public let url: URL
    public let conflict: ConflictResolution

    public init(url: URL, conflict: ConflictResolution) {
        self.url = url
        self.conflict = conflict
    }
}

/// Decides how each dropped item handles a name clash, asking the user only about clashes.
@MainActor
public enum UploadPlanner {
    public static func plan(_ urls: [URL], existingNames: Set<String>, defaultChoice: ConflictChoice?,
                            ask: (ConflictQuestion) async -> ConflictAnswer) async -> [PlannedUpload] {
        // A name clashes with the folder or with an earlier item of the same drop, ignoring case.
        var seen = Set(existingNames.map(\.nameKey))
        let clashes = urls.map { url in
            let name = url.lastPathComponent.nameKey
            defer { seen.insert(name) }
            return seen.contains(name)
        }

        var remaining = clashes.filter { $0 }.count
        var remembered = defaultChoice
        var result: [PlannedUpload] = []
        for (url, clash) in zip(urls, clashes) {
            guard clash else {
                result.append(PlannedUpload(url: url, conflict: .fail))
                continue
            }
            remaining -= 1
            let choice: ConflictChoice
            if let remembered {
                choice = remembered
            } else {
                let answer = await ask(ConflictQuestion(name: url.lastPathComponent, remaining: remaining))
                choice = answer.choice
                if answer.applyToAll { remembered = answer.choice }
            }
            switch choice {
            case .skip: continue
            case .replace: result.append(PlannedUpload(url: url, conflict: .replace))
            case .keepBoth: result.append(PlannedUpload(url: url, conflict: .keepBoth))
            }
        }
        return result
    }
}
