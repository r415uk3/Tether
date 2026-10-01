import Foundation

@objc public protocol MTPXPCProtocol {
    /// One generic RPC: `request` is a JSON `XPCRequest`, the reply a JSON `XPCResponse`.
    func call(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

@objc public protocol MTPXPCEventsProtocol {
    /// `payload` is a JSON `ServiceEvent`.
    func event(_ payload: Data)
}

enum XPCRequest: Codable, Sendable, Equatable {
    case devices
    case storages(deviceID: DeviceID)
    case list(FolderRef)
    case download(jobID: UUID, entry: FileEntry, deviceID: DeviceID, directory: URL)
    case upload(jobID: UUID, fileURL: URL, folder: FolderRef)
    case createFolder(name: String, folder: FolderRef)
    case rename(objectID: UInt32, deviceID: DeviceID, newName: String)
    case delete(objectID: UInt32, deviceID: DeviceID)
    case cancel(jobID: UUID)
}

enum XPCResponse: Codable, Sendable {
    case devices([DeviceInfo])
    case storages([StorageInfo])
    case entries([FileEntry])
    case entry(FileEntry)
    case url(URL)
    case ok
    case failure(MTPError)
}

enum XPCCodec {
    static func encode<T: Encodable>(_ value: T) -> Data {
        do { return try JSONEncoder().encode(value) } catch { preconditionFailure("XPC encode failed: \(error)") }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
