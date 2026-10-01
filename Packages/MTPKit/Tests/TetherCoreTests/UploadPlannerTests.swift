import Foundation
import Testing
import MTPKit
@testable import TetherCore

@MainActor
@Suite struct UploadPlannerTests {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func noClashesNeverAsks() async {
        var asked = 0
        let plan = await UploadPlanner.plan([url("/m/a.txt"), url("/m/b.txt")], existingNames: ["c.txt"],
                                            defaultChoice: nil) { _ in asked += 1; return .init(choice: .skip, applyToAll: false) }
        #expect(asked == 0)
        #expect(plan == [.init(url: url("/m/a.txt"), conflict: .fail), .init(url: url("/m/b.txt"), conflict: .fail)])
    }

    @Test func asksPerClashAndMapsChoices() async {
        var questions: [ConflictQuestion] = []
        var answers: [ConflictChoice] = [.replace, .skip]
        let plan = await UploadPlanner.plan([url("/m/a"), url("/m/b"), url("/m/c")], existingNames: ["a", "b"],
                                            defaultChoice: nil) { q in
            questions.append(q)
            return .init(choice: answers.removeFirst(), applyToAll: false)
        }
        #expect(questions == [.init(name: "a", remaining: 1), .init(name: "b", remaining: 0)])
        #expect(plan == [.init(url: url("/m/a"), conflict: .replace), .init(url: url("/m/c"), conflict: .fail)])
    }

    @Test func applyToAllReusesAnswer() async {
        var asked = 0
        let plan = await UploadPlanner.plan([url("/m/a"), url("/m/b")], existingNames: ["a", "b"],
                                            defaultChoice: nil) { _ in
            asked += 1
            return .init(choice: .keepBoth, applyToAll: true)
        }
        #expect(asked == 1)
        #expect(plan.map(\.conflict) == [.keepBoth, .keepBoth])
    }

    @Test func defaultChoiceAnswersWithoutAsking() async {
        var asked = 0
        let plan = await UploadPlanner.plan([url("/m/a"), url("/m/new")], existingNames: ["a"],
                                            defaultChoice: .skip) { _ in asked += 1; return .init(choice: .replace, applyToAll: false) }
        #expect(asked == 0)
        #expect(plan == [.init(url: url("/m/new"), conflict: .fail)])
    }

    @Test func duplicateNamesWithinOneDropAreConflicts() async {
        var questions: [ConflictQuestion] = []
        let plan = await UploadPlanner.plan([url("/x/a.txt"), url("/y/a.txt")], existingNames: [],
                                            defaultChoice: nil) { q in
            questions.append(q)
            return .init(choice: .keepBoth, applyToAll: false)
        }
        #expect(questions == [.init(name: "a.txt", remaining: 0)])
        #expect(plan == [.init(url: url("/x/a.txt"), conflict: .fail), .init(url: url("/y/a.txt"), conflict: .keepBoth)])
    }
}
