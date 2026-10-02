import Foundation

/// Helper-side adapter: decodes requests, calls the wrapped service, forwards events to the app.
public final class MTPXPCEndpoint: NSObject, MTPXPCProtocol, @unchecked Sendable {
    private let service: any MTPService

    private init(service: any MTPService) {
        self.service = service
    }

    /// Configures and resumes an accepted connection. Call from `listener(_:shouldAcceptNewConnection:)`.
    public static func accept(_ connection: NSXPCConnection, service: any MTPService) {
        connection.exportedInterface = NSXPCInterface(with: MTPXPCProtocol.self)
        connection.exportedObject = MTPXPCEndpoint(service: service)
        connection.remoteObjectInterface = NSXPCInterface(with: MTPXPCEventsProtocol.self)
        let events = Unchecked(connection.remoteObjectProxy as? MTPXPCEventsProtocol)
        connection.resume()
        Task {
            await service.setEventHandler { event in
                events.value?.event(XPCCodec.encode(event))
            }
        }
    }

    public func call(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        let service = self.service
        Task {
            let response: XPCResponse
            do {
                response = try await Self.handle(XPCCodec.decode(XPCRequest.self, from: request), service: service)
            } catch {
                response = .failure(MTPError.from(error))
            }
            reply(XPCCodec.encode(response))
        }
    }

    private static func handle(_ request: XPCRequest, service: any MTPService) async throws -> XPCResponse {
        switch request {
        case .devices:
            return .devices(try await service.devices())
        case .storages(let deviceID):
            return .storages(try await service.storages(deviceID: deviceID))
        case .list(let folder):
            return .entries(try await service.list(folder))
        case .download(let jobID, let entry, let deviceID, let directory):
            return .url(try await service.download(jobID: jobID, entry: entry, deviceID: deviceID, into: directory))
        case .upload(let jobID, let fileURL, let folder, let conflict):
            return .entry(try await service.upload(jobID: jobID, fileURL: fileURL, to: folder, conflict: conflict))
        case .createFolder(let name, let folder):
            return .entry(try await service.createFolder(named: name, in: folder))
        case .rename(let entry, let folder, let newName):
            try await service.rename(entry, in: folder, to: newName)
            return .ok
        case .delete(let entry, let folder):
            try await service.delete(entry, in: folder)
            return .ok
        case .thumbnail(let objectID, let folder):
            return .thumbnail(try await service.thumbnail(objectID: objectID, in: folder))
        case .releaseDevice(let id):
            try await service.releaseDevice(id)
            return .ok
        case .ejectDevice(let id):
            try await service.ejectDevice(id)
            return .ok
        case .diagnostics:
            return .lines(try await service.diagnostics())
        case .cancel(let jobID):
            await service.cancel(jobID: jobID)
            return .ok
        }
    }
}
