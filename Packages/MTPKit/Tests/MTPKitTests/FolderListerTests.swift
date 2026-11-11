import Foundation
import Testing
@testable import MTPKit

private func entry(_ id: UInt32) -> FileEntry {
    FileEntry(objectID: id, parentID: 7, storageID: 1, name: "f\(id)", size: 1, modified: nil, isFolder: false)
}

/// Records which way each object was read.
private final class Calls: @unchecked Sendable {
    var bulk = 0
    var single: [UInt32] = []
    var slow: [UInt32] = []
    var progress: [UInt64] = []
}

private func list(_ handles: [UInt32], folder: UInt32 = 7, bulkAllowed: Bool = true,
                  bulk: (([UInt32]) -> [FileEntry?]?)? = nil,
                  single: ((UInt32) -> FileEntry?)? = nil,
                  slow: ((UInt32) -> FileEntry?)? = nil,
                  cancelAfter: UInt64? = nil, calls: Calls) throws -> [FileEntry] {
    try FolderLister.list(
        handles: handles, folderID: folder, bulkAllowed: bulkAllowed,
        bulk: { calls.bulk += 1; return (bulk ?? { $0.map(entry) })($0) },
        single: { calls.single.append($0); return (single ?? entry)($0) },
        slow: { calls.slow.append($0); return (slow ?? entry)($0) },
        progress: { done, _ in calls.progress.append(done); return cancelAfter.map { done < $0 } ?? true })
}

@Test func bulkReadsTheWholeFolderInOneRequest() throws {
    let calls = Calls()
    let result = try list([1, 2, 3], calls: calls)
    #expect(result.map(\.objectID) == [1, 2, 3])
    #expect(calls.bulk == 1)
    #expect(calls.single.isEmpty && calls.slow.isEmpty)
    #expect(calls.progress.first == 0 && calls.progress.last == 3)
}

@Test func objectsMissingFromTheBulkReplyAreReadOneByOne() throws {
    let calls = Calls()
    let result = try list([1, 2, 3], bulk: { $0.map { $0 == 2 ? nil : entry($0) } }, calls: calls)
    #expect(result.map(\.objectID) == [1, 2, 3])
    #expect(calls.single == [2])
    #expect(calls.slow.isEmpty)
}

@Test func refusedBulkFallsBackToPerObjectRequests() throws {
    let calls = Calls()
    let result = try list([1, 2], bulk: { _ in nil }, calls: calls)
    #expect(result.map(\.objectID) == [1, 2])
    #expect(calls.single == [1, 2])
}

@Test func storageRootIsNeverReadInBulk() throws {
    let calls = Calls()
    _ = try list([1, 2], folder: FileEntry.rootID, calls: calls)
    #expect(calls.bulk == 0)
    #expect(calls.single == [1, 2])
}

@Test func hugeFoldersAreReadPerObjectSoProgressKeepsFlowing() throws {
    let calls = Calls()
    let handles = (1...UInt32(FolderLister.bulkLimit + 1)).map { $0 }
    _ = try list(handles, calls: calls)
    #expect(calls.bulk == 0)
    #expect(calls.single.count == handles.count)
}

@Test func bulkIsSkippedWhenDisallowed() throws {
    let calls = Calls()
    _ = try list([1], bulkAllowed: false, calls: calls)
    #expect(calls.bulk == 0)
}

@Test func objectsThePropertyListCannotDescribeUseGetObjectInfo() throws {
    let calls = Calls()
    let result = try list([1, 2], bulk: { _ in nil }, single: { $0 == 1 ? nil : entry($0) }, calls: calls)
    #expect(result.map(\.objectID) == [1, 2])
    #expect(calls.slow == [1])
}

@Test func afterRepeatedPropertyListFailuresOnlyGetObjectInfoIsUsed() throws {
    let calls = Calls()
    let result = try list(Array(1...6), bulk: { _ in nil }, single: { _ in nil }, calls: calls)
    #expect(result.count == 6)
    #expect(calls.single == [1, 2, 3])
    #expect(calls.slow == [1, 2, 3, 4, 5, 6])
}

/// A failed read is not progress: a phone timing out on every object must still trip the idle timeout.
@Test func vanishedObjectsAreSkippedWithoutReportingProgress() throws {
    let calls = Calls()
    let result = try list([1, 2, 3], bulkAllowed: false, single: { $0 == 2 ? nil : entry($0) },
                          slow: { $0 == 2 ? nil : entry($0) }, calls: calls)
    #expect(result.map(\.objectID) == [1, 3])
    #expect(calls.progress == [1, 3])
}

@Test func cancellingThroughProgressStopsTheListing() {
    let calls = Calls()
    #expect(throws: MTPError.cancelled) {
        try list([1, 2, 3], bulkAllowed: false, cancelAfter: 2, calls: calls)
    }
    #expect(calls.single == [1, 2])
}

@Test func bulkGuardDisablesAModelWhoseBulkRequestNeverFinished() {
    let defaults = UserDefaults(suiteName: "BulkGuard-\(UUID())")!
    let first = BulkListingGuard(model: "vivo X", defaults: defaults)
    #expect(first.isAllowed)
    first.begin() // the helper is killed before end()
    let next = BulkListingGuard(model: "vivo X", defaults: defaults)
    #expect(!next.isAllowed)
    #expect(BulkListingGuard(model: "Pixel 9", defaults: defaults).isAllowed)
}

@Test func bulkGuardStaysAllowedAfterACompletedRequest() {
    let defaults = UserDefaults(suiteName: "BulkGuard-\(UUID())")!
    let first = BulkListingGuard(model: "vivo X", defaults: defaults)
    first.begin()
    first.end()
    #expect(BulkListingGuard(model: "vivo X", defaults: defaults).isAllowed)
}
