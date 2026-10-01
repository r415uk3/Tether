import CryptoKit
import Foundation
import MTPKit

/// Identifies one version of one phone item for on-disk caches. A changed size or date means a new key.
public struct ItemKey: Hashable, Sendable {
    public let deviceID: DeviceID
    public let storageID: UInt32
    public let objectID: UInt32
    public let size: UInt64
    public let modified: Date?

    public init(entry: FileEntry, deviceID: DeviceID) {
        self.deviceID = deviceID
        storageID = entry.storageID
        objectID = entry.objectID
        size = entry.size
        modified = entry.modified
    }

    /// A filesystem-safe, collision-resistant name for this key.
    public var fileName: String {
        let raw = "\(deviceID)|\(storageID)|\(objectID)|\(size)|\(modified?.timeIntervalSince1970 ?? 0)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
