import Foundation

/// In-memory phone for tests, previews and `-UseFakeDevices`.
public final class FakeDevice: MTPDevice, @unchecked Sendable {
    public enum Fault: Sendable, Equatable {
        case fail(MTPError)
        case disconnectAfter(bytes: UInt64)
        case hang
    }

    private struct Node {
        var entry: FileEntry
        var data: Data
    }

    public let info: DeviceInfo
    private let chunkSize: Int
    private let chunkDelay: TimeInterval
    private let lock = NSLock()
    private let hangGate = DispatchSemaphore(value: 0)
    private var storageList: [StorageInfo]
    private var nodes: [UInt32: Node] = [:]
    private var nextID: UInt32 = 1
    private var faults: [Fault] = []
    private var disconnected = false
    private var closed = false

    public init(id: DeviceID = "fake-1", manufacturer: String = "Google", model: String = "Pixel 9",
                storages: [StorageInfo] = [StorageInfo(id: 1, name: "Internal shared storage",
                                                       capacity: 128_000_000_000, freeSpace: 64_000_000_000)],
                chunkSize: Int = 4096, chunkDelay: TimeInterval = 0) {
        self.info = DeviceInfo(id: id, manufacturer: manufacturer, model: model, state: .ready)
        self.storageList = storages
        self.chunkSize = chunkSize
        self.chunkDelay = chunkDelay
    }

    // MARK: Test setup and inspection

    @discardableResult
    public func addFolder(_ name: String, in parentID: UInt32 = FileEntry.rootID, storageID: UInt32 = 1) -> FileEntry {
        lock.withLock { insert(name: name, data: Data(), parentID: parentID, storageID: storageID, isFolder: true, modified: nil) }
    }

    @discardableResult
    public func addFile(_ name: String, data: Data, in parentID: UInt32 = FileEntry.rootID, storageID: UInt32 = 1,
                        modified: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> FileEntry {
        lock.withLock { insert(name: name, data: data, parentID: parentID, storageID: storageID, isFolder: false, modified: modified) }
    }

    public func inject(_ fault: Fault) { lock.withLock { faults.append(fault) } }
    public func releaseHang() { hangGate.signal() }
    public func data(of objectID: UInt32) -> Data? { lock.withLock { nodes[objectID]?.data } }
    public func storage(_ id: UInt32) -> StorageInfo? { lock.withLock { storageList.first { $0.id == id } } }
    public var isClosed: Bool { lock.withLock { closed } }

    public func children(of parentID: UInt32, storageID: UInt32 = 1) -> [FileEntry] {
        lock.withLock {
            nodes.values.map(\.entry)
                .filter { $0.parentID == parentID && $0.storageID == storageID }
                .sorted { $0.objectID < $1.objectID }
        }
    }

    // MARK: MTPDevice

    public func storages() throws -> [StorageInfo] {
        try beginSimple()
        return lock.withLock { storageList }
    }

    public func listFolder(storageID: UInt32, folderID: UInt32) throws -> [FileEntry] {
        try beginSimple()
        try lock.withLock { try requireFolder(folderID) }
        return children(of: folderID, storageID: storageID)
    }

    public func download(objectID: UInt32, to fileURL: URL, progress: ProgressHandler) throws {
        let limit = try beginTransfer()
        guard let data = lock.withLock({ nodes[objectID]?.data }) else { throw MTPError.notFound }
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw MTPError.underlying(code: -1, message: "Cannot create \(fileURL.path)")
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        let total = UInt64(data.count)
        var done: UInt64 = 0
        while done < total {
            if let limit, done >= limit { markDisconnected(); throw MTPError.deviceDisconnected }
            let end = min(done + UInt64(chunkSize), total)
            try handle.write(contentsOf: data[Int(done)..<Int(end)])
            done = end
            if chunkDelay > 0 { Thread.sleep(forTimeInterval: chunkDelay) }
            if !progress(done, total) { throw MTPError.cancelled }
        }
    }

    public func upload(from fileURL: URL, name: String, size: UInt64, storageID: UInt32, parentID: UInt32,
                       progress: ProgressHandler) throws -> FileEntry {
        let limit = try beginTransfer()
        let entry: FileEntry = try lock.withLock {
            try requireFolder(parentID)
            guard let index = storageList.firstIndex(where: { $0.id == storageID }) else { throw MTPError.notFound }
            if storageList[index].freeSpace < size {
                throw MTPError.storageFull(needed: size, available: storageList[index].freeSpace)
            }
            return insert(name: name, data: Data(), parentID: parentID, storageID: storageID, isFolder: false, modified: Date())
        }
        let source = try Data(contentsOf: fileURL)
        let total = UInt64(source.count)
        var done: UInt64 = 0
        while done < total {
            if let limit, done >= limit { markDisconnected(); throw MTPError.deviceDisconnected }
            let end = min(done + UInt64(chunkSize), total)
            let chunk = source[Int(done)..<Int(end)]
            lock.withLock { nodes[entry.objectID]?.data.append(chunk) }
            done = end
            if chunkDelay > 0 { Thread.sleep(forTimeInterval: chunkDelay) }
            if !progress(done, total) { throw MTPError.cancelled }
        }
        return lock.withLock {
            nodes[entry.objectID]?.entry.size = total
            if let index = storageList.firstIndex(where: { $0.id == storageID }) {
                storageList[index].freeSpace -= min(total, storageList[index].freeSpace)
            }
            return nodes[entry.objectID]!.entry
        }
    }

    public func createFolder(name: String, storageID: UInt32, parentID: UInt32) throws -> FileEntry {
        try beginSimple()
        return try lock.withLock {
            try requireFolder(parentID)
            return insert(name: name, data: Data(), parentID: parentID, storageID: storageID, isFolder: true, modified: Date())
        }
    }

    public func rename(objectID: UInt32, to newName: String) throws {
        try beginSimple()
        try lock.withLock {
            guard nodes[objectID] != nil else { throw MTPError.notFound }
            nodes[objectID]!.entry.name = newName
        }
    }

    public func delete(objectID: UInt32) throws {
        try beginSimple()
        try lock.withLock {
            guard nodes[objectID] != nil else { throw MTPError.notFound }
            removeSubtree(objectID)
        }
    }

    public func close() { lock.withLock { closed = true } }

    // MARK: Internals (call with lock held unless noted)

    private func insert(name: String, data: Data, parentID: UInt32, storageID: UInt32, isFolder: Bool, modified: Date?) -> FileEntry {
        let entry = FileEntry(objectID: nextID, parentID: parentID, storageID: storageID, name: name,
                              size: UInt64(data.count), modified: modified, isFolder: isFolder)
        nodes[nextID] = Node(entry: entry, data: data)
        nextID += 1
        return entry
    }

    private func requireFolder(_ id: UInt32) throws {
        if id == FileEntry.rootID { return }
        guard let node = nodes[id], node.entry.isFolder else { throw MTPError.notFound }
    }

    private func removeSubtree(_ id: UInt32) {
        for child in nodes.values where child.entry.parentID == id { removeSubtree(child.entry.objectID) }
        nodes[id] = nil
    }

    private func markDisconnected() { lock.withLock { disconnected = true } }

    /// Lock NOT held. Consumes one fault; returns a byte limit for `.disconnectAfter`.
    private func beginTransfer() throws -> UInt64? {
        let fault: Fault? = try lock.withLock {
            if disconnected { throw MTPError.deviceDisconnected }
            return faults.isEmpty ? nil : faults.removeFirst()
        }
        switch fault {
        case .fail(let error): throw error
        case .hang: hangGate.wait(); return nil
        case .disconnectAfter(let bytes): return bytes
        case nil: return nil
        }
    }

    /// Lock NOT held. Non-transfer operations treat `.disconnectAfter` as an immediate disconnect.
    private func beginSimple() throws {
        if try beginTransfer() != nil {
            markDisconnected()
            throw MTPError.deviceDisconnected
        }
    }
}
