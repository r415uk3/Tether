import Foundation

/// Called during transfers with bytes done / total. Return `false` to cancel.
public typealias ProgressHandler = (_ done: UInt64, _ total: UInt64) -> Bool

/// One connected phone. Implementations are not thread-safe;
/// `DeviceWorker` guarantees that all calls happen on one thread.
public protocol MTPDevice: AnyObject, Sendable {
    var info: DeviceInfo { get }
    func storages() throws -> [StorageInfo]
    func listFolder(storageID: UInt32, folderID: UInt32) throws -> [FileEntry]
    func download(objectID: UInt32, to fileURL: URL, progress: ProgressHandler) throws
    func upload(from fileURL: URL, name: String, size: UInt64, storageID: UInt32, parentID: UInt32,
                progress: ProgressHandler) throws -> FileEntry
    func createFolder(name: String, storageID: UInt32, parentID: UInt32) throws -> FileEntry
    func rename(objectID: UInt32, to newName: String) throws
    func delete(objectID: UInt32) throws
    func close()
}

public struct AttachedDevice: Hashable, Sendable {
    public let id: DeviceID
    public let manufacturer: String
    public let model: String

    public init(id: DeviceID, manufacturer: String, model: String) {
        self.id = id
        self.manufacturer = manufacturer
        self.model = model
    }
}

/// Finds and opens phones. `attachedDevices()` must be cheap; `open` may block for seconds.
public protocol DeviceProvider: Sendable {
    func attachedDevices() -> [AttachedDevice]
    func open(_ device: AttachedDevice) throws -> any MTPDevice
}
