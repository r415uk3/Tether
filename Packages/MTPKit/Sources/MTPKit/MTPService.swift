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
    /// The phone's thumbnail for an object in `folder`, fetched at background priority; nil if none.
    func thumbnail(objectID: UInt32, in folder: FolderRef) async throws -> Data?
    func download(jobID: UUID, entry: FileEntry, deviceID: DeviceID, into directory: URL) async throws -> URL
    func upload(jobID: UUID, fileURL: URL, to folder: FolderRef, conflict: ConflictResolution) async throws -> FileEntry
    func createFolder(named name: String, in folder: FolderRef) async throws -> FileEntry
    /// Verifies `entry` still names the same item, then renames it.
    func rename(_ entry: FileEntry, in folder: FolderRef, to newName: String) async throws
    /// Verifies `entry` still names the same item, then deletes it (folders recursively).
    func delete(_ entry: FileEntry, in folder: FolderRef) async throws
    func cancel(jobID: UUID) async
    /// Abandons all device state and in-flight calls, then reconnects. Used by watchdogs.
    func restart() async
    /// Frees a phone held by Image Capture and reconnects. Throws `.claimedByOtherProcess` if it stays held.
    func releaseDevice(_ deviceID: DeviceID) async throws
    /// The service process's recent log lines (the helper's when over XPC). Never contains names or serials.
    func diagnostics() async throws -> [String]
}

public extension MTPService {
    /// Upload that refuses name clashes (`.fail`).
    func upload(jobID: UUID, fileURL: URL, to folder: FolderRef) async throws -> FileEntry {
        try await upload(jobID: jobID, fileURL: fileURL, to: folder, conflict: .fail)
    }
}
