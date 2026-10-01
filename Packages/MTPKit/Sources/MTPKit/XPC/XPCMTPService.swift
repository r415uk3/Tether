import Foundation

/// App-side MTPService that forwards every call to MTPHelper.xpc.
public final class XPCMTPService: MTPService, @unchecked Sendable {
    private let makeConnection: @Sendable () -> NSXPCConnection
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private let sink = EventSink()

    public init(makeConnection: @escaping @Sendable () -> NSXPCConnection) {
        self.makeConnection = makeConnection
    }

    public static func helper() -> XPCMTPService {
        XPCMTPService { NSXPCConnection(serviceName: MTPHelperConstants.serviceName) }
    }

    public func setEventHandler(_ handler: @escaping @Sendable (ServiceEvent) -> Void) async {
        sink.setHandler(handler)
    }

    public func devices() async throws -> [DeviceInfo] {
        guard case .devices(let devices) = try await send(.devices) else { throw MTPError.unexpectedResponse }
        return devices
    }

    public func storages(deviceID: DeviceID) async throws -> [StorageInfo] {
        guard case .storages(let storages) = try await send(.storages(deviceID: deviceID)) else { throw MTPError.unexpectedResponse }
        return storages
    }

    public func list(_ folder: FolderRef) async throws -> [FileEntry] {
        guard case .entries(let entries) = try await send(.list(folder)) else { throw MTPError.unexpectedResponse }
        return entries
    }

    public func download(jobID: UUID, entry: FileEntry, deviceID: DeviceID, into directory: URL) async throws -> URL {
        let request = XPCRequest.download(jobID: jobID, entry: entry, deviceID: deviceID, directory: directory)
        guard case .url(let url) = try await send(request) else { throw MTPError.unexpectedResponse }
        return url
    }

    public func upload(jobID: UUID, fileURL: URL, to folder: FolderRef,
                       conflict: ConflictResolution) async throws -> FileEntry {
        let request = XPCRequest.upload(jobID: jobID, fileURL: fileURL, folder: folder, conflict: conflict)
        guard case .entry(let entry) = try await send(request) else { throw MTPError.unexpectedResponse }
        return entry
    }

    public func createFolder(named name: String, in folder: FolderRef) async throws -> FileEntry {
        guard case .entry(let entry) = try await send(.createFolder(name: name, folder: folder)) else {
            throw MTPError.unexpectedResponse
        }
        return entry
    }

    public func rename(_ entry: FileEntry, in folder: FolderRef, to newName: String) async throws {
        _ = try await send(.rename(entry: entry, folder: folder, newName: newName))
    }

    public func delete(_ entry: FileEntry, in folder: FolderRef) async throws {
        _ = try await send(.delete(entry: entry, folder: folder))
    }

    public func cancel(jobID: UUID) async {
        _ = try? await send(.cancel(jobID: jobID))
    }

    /// Kills a hung helper and drops the connection; the next call relaunches it.
    public func restart() async {
        let old: NSXPCConnection? = lock.withLock {
            defer { connection = nil }
            return connection
        }
        guard let old else { return }
        let pid = old.processIdentifier
        if pid > 0 && pid != getpid() { kill(pid, SIGKILL) }
        old.invalidate()
    }

    // MARK: Internals

    private func currentConnection() -> NSXPCConnection {
        lock.withLock {
            if let connection { return connection }
            let connection = makeConnection()
            connection.remoteObjectInterface = NSXPCInterface(with: MTPXPCProtocol.self)
            connection.exportedInterface = NSXPCInterface(with: MTPXPCEventsProtocol.self)
            connection.exportedObject = sink
            let id = ObjectIdentifier(connection)
            connection.interruptionHandler = { [weak self] in self?.sink.deliver(.interrupted) }
            connection.invalidationHandler = { [weak self] in self?.connectionInvalidated(id) }
            connection.resume()
            self.connection = connection
            return connection
        }
    }

    private func connectionInvalidated(_ id: ObjectIdentifier) {
        lock.withLock {
            if let connection, ObjectIdentifier(connection) == id { self.connection = nil }
        }
        sink.deliver(.interrupted)
    }

    private func send(_ request: XPCRequest) async throws -> XPCResponse {
        let connection = Unchecked(currentConnection())
        let payload = XPCCodec.encode(request)
        let response: XPCResponse = try await withCheckedThrowingContinuation { continuation in
            let once = OnceContinuation(continuation)
            let proxy = connection.value.remoteObjectProxyWithErrorHandler { _ in
                once.resume(throwing: MTPError.serviceInterrupted)
            } as? MTPXPCProtocol
            guard let proxy else {
                once.resume(throwing: MTPError.serviceInterrupted)
                return
            }
            proxy.call(payload) { data in
                do { once.resume(returning: try XPCCodec.decode(XPCResponse.self, from: data)) }
                catch { once.resume(throwing: MTPError.from(error)) }
            }
        }
        if case .failure(let error) = response { throw error }
        return response
    }
}

private final class EventSink: NSObject, MTPXPCEventsProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (ServiceEvent) -> Void)?

    func setHandler(_ handler: @escaping @Sendable (ServiceEvent) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func deliver(_ event: ServiceEvent) {
        let handler = lock.withLock { self.handler }
        handler?(event)
    }

    func event(_ payload: Data) {
        if let event = try? XPCCodec.decode(ServiceEvent.self, from: payload) { deliver(event) }
    }
}
