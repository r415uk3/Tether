import Foundation
import Testing
@testable import MTPKit

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

@Test func fileEntryRoundTripsLargeSize() throws {
    let entry = FileEntry(objectID: 7, parentID: FileEntry.rootID, storageID: 0x10001,
                          name: "movie.mkv", size: 5_368_709_120,
                          modified: Date(timeIntervalSince1970: 1_700_000_000), isFolder: false)
    #expect(try roundTrip(entry) == entry)
    #expect(try roundTrip(entry).size == 5_368_709_120)
}

@Test func deviceInfoRoundTripsUnavailableState() throws {
    let info = DeviceInfo(id: "1-4", manufacturer: "Samsung", model: "Galaxy S25",
                          state: .unavailable(.storageFull(needed: 10, available: 2)))
    #expect(try roundTrip(info) == info)
}

@Test func displayNameFallsBackToManufacturer() {
    #expect(DeviceInfo(id: "a", manufacturer: "Google", model: "", state: .ready).displayName == "Google")
    #expect(DeviceInfo(id: "a", manufacturer: "Google", model: "Pixel 9", state: .ready).displayName == "Pixel 9")
}

@Test func folderRefDefaultsToRoot() {
    #expect(FolderRef(deviceID: "d", storageID: 1).folderID == FileEntry.rootID)
}

@Test func errorFromWrapsForeignErrors() {
    #expect(MTPError.from(MTPError.timeout) == .timeout)
    let wrapped = MTPError.from(CocoaError(.fileNoSuchFile))
    guard case .underlying(let code, _) = wrapped else { Issue.record("expected underlying"); return }
    #expect(code == CocoaError.fileNoSuchFile.rawValue)
}

@Test func everyErrorHasAMessage() {
    let all: [MTPError] = [.deviceDisconnected, .deviceLocked, .deviceBusy, .claimedByOtherProcess,
                           .storageFull(needed: 2_000_000_000, available: 1_000), .nameConflict("a.txt"),
                           .notFound, .timeout, .cancelled, .serviceInterrupted,
                           .underlying(code: 1, message: "boom")]
    for error in all { #expect(!(error.errorDescription ?? "").isEmpty) }
    #expect(MTPError.nameConflict("a.txt").errorDescription!.contains("a.txt"))
}
