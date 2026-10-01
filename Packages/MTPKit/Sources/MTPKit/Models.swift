import Foundation

public typealias DeviceID = String

public enum DeviceState: Codable, Hashable, Sendable {
    case ready
    case unavailable(MTPError)
}

public struct DeviceInfo: Codable, Hashable, Sendable, Identifiable {
    public let id: DeviceID
    public var manufacturer: String
    public var model: String
    public var state: DeviceState

    public init(id: DeviceID, manufacturer: String, model: String, state: DeviceState) {
        self.id = id
        self.manufacturer = manufacturer
        self.model = model
        self.state = state
    }

    public var displayName: String { model.isEmpty ? manufacturer : model }
}

public struct StorageInfo: Codable, Hashable, Sendable, Identifiable {
    public let id: UInt32
    public var name: String
    public var capacity: UInt64
    public var freeSpace: UInt64

    public init(id: UInt32, name: String, capacity: UInt64, freeSpace: UInt64) {
        self.id = id
        self.name = name
        self.capacity = capacity
        self.freeSpace = freeSpace
    }
}

public struct FileEntry: Codable, Hashable, Sendable, Identifiable {
    /// MTP's "root of storage" folder ID, used when listing.
    public static let rootID: UInt32 = 0xFFFF_FFFF

    public let objectID: UInt32
    public var parentID: UInt32
    public var storageID: UInt32
    public var name: String
    public var size: UInt64
    public var modified: Date?
    public var isFolder: Bool

    public init(objectID: UInt32, parentID: UInt32, storageID: UInt32, name: String,
                size: UInt64, modified: Date?, isFolder: Bool) {
        self.objectID = objectID
        self.parentID = parentID
        self.storageID = storageID
        self.name = name
        self.size = size
        self.modified = modified
        self.isFolder = isFolder
    }

    public var id: UInt32 { objectID }
}

public struct FolderRef: Codable, Hashable, Sendable {
    public let deviceID: DeviceID
    public let storageID: UInt32
    public let folderID: UInt32

    public init(deviceID: DeviceID, storageID: UInt32, folderID: UInt32 = FileEntry.rootID) {
        self.deviceID = deviceID
        self.storageID = storageID
        self.folderID = folderID
    }
}

extension String {
    /// The key two names are compared by when checking for clashes on the phone. Android shared storage
    /// (emulated /sdcard, FAT/exFAT cards) is case-insensitive, so "B.txt" and "b.txt" are the same name.
    public var nameKey: String { lowercased() }
}
