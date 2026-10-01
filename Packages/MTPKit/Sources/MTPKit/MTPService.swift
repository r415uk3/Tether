import Foundation

public enum ServiceEvent: Codable, Sendable, Equatable {
    case devicesChanged([DeviceInfo])
    case progress(jobID: UUID, done: UInt64, total: UInt64)
    /// The service lost its state (helper restarted). In-flight calls have failed.
    case interrupted
}

/// Everything the app needs from the phone layer. Implemented in-process by `LocalMTPService`
/// (tests, previews, inside MTPHelper) and over XPC by `XPCMTPService`.
public protocol MTPService: Sendable {
    func setEventHandler(_ handler: @escaping @Sendable (ServiceEvent) -> Void) async
    func devices() async throws -> [DeviceInfo]
    func storages(deviceID: DeviceID) async throws -> [StorageInfo]
    func list(_ folder: FolderRef) async throws -> [FileEntry]
    func download(jobID: UUID, entry: FileEntry, deviceID: DeviceID, into directory: URL) async throws -> URL
    func upload(jobID: UUID, fileURL: URL, to folder: FolderRef) async throws -> FileEntry
    func createFolder(named name: String, in folder: FolderRef) async throws -> FileEntry
    func rename(objectID: UInt32, deviceID: DeviceID, to newName: String) async throws
    func delete(objectID: UInt32, deviceID: DeviceID) async throws
    func cancel(jobID: UUID) async
    /// Abandons all device state and in-flight calls, then reconnects. Used by watchdogs.
    func restart() async
}
