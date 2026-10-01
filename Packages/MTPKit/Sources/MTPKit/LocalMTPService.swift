import Foundation

public actor LocalMTPService: MTPService {
    private let provider: any DeviceProvider
    private var workers: [DeviceID: DeviceWorker] = [:]
    private var infos: [DeviceID: DeviceInfo] = [:]
    /// In-flight opens: device -> epoch of the restart generation that started the open.
    private var opening: [DeviceID: Int] = [:]
    /// Bumped whenever a rescan sees the device absent, so a handle opened before an unplug/replug is stale.
    private var generations: [DeviceID: Int] = [:]
    /// Bumped by `restart()`; opens started in an older epoch are discarded.
    private var epoch = 0
    private var lastAttached: Set<DeviceID> = []
    private var hasScanned = false
    private var eventHandler: (@Sendable (ServiceEvent) -> Void)?
    private let cancellations = CancellationRegistry()

    public init(provider: any DeviceProvider) {
        self.provider = provider
    }

    public var hasUnavailableDevices: Bool {
        infos.values.contains { $0.state != .ready }
    }

    public func setEventHandler(_ handler: @escaping @Sendable (ServiceEvent) -> Void) {
        eventHandler = handler
    }

    public func devices() async throws -> [DeviceInfo] {
        if !hasScanned { await rescan() }
        return sortedDevices()
    }

    public func rescan() async {
        hasScanned = true
        let attached = provider.attachedDevices()
        lastAttached = Set(attached.map(\.id))

        for id in Set(infos.keys).union(opening.keys) where !lastAttached.contains(id) {
            generations[id, default: 0] += 1
            workers.removeValue(forKey: id)?.shutdown(reason: .deviceDisconnected)
            infos[id] = nil
        }

        for device in attached where workers[device.id] == nil && opening[device.id] == nil {
            guard lastAttached.contains(device.id) else { continue } // removed by a concurrent rescan
            let startEpoch = epoch
            let generation = generations[device.id, default: 0]
            opening[device.id] = startEpoch
            let provider = self.provider
            let result = await Task.detached { () -> Result<any MTPDevice, MTPError> in
                do { return .success(try provider.open(device)) } catch { return .failure(MTPError.from(error)) }
            }.value
            if opening[device.id] == startEpoch { opening[device.id] = nil }

            // Reentrancy: the device may have been unplugged/replugged or the service restarted while opening.
            let current = epoch == startEpoch && lastAttached.contains(device.id)
                && generations[device.id, default: 0] == generation && workers[device.id] == nil
            switch result {
            case .success(let opened):
                guard current else { opened.close(); continue }
                workers[device.id] = DeviceWorker(device: opened, name: device.model)
                infos[device.id] = opened.info
            case .failure(let error):
                guard current else { continue }
                infos[device.id] = DeviceInfo(id: device.id, manufacturer: device.manufacturer,
                                              model: device.model, state: .unavailable(error))
            }
        }
        emit(.devicesChanged(sortedDevices()))
    }

    public func restart() async {
        for worker in workers.values { worker.shutdown(reason: .serviceInterrupted) }
        workers.removeAll()
        infos.removeAll()
        epoch += 1
        opening.removeAll()
        emit(.interrupted)
        await rescan()
    }

    public func storages(deviceID: DeviceID) async throws -> [StorageInfo] {
        try await worker(deviceID).perform(.interactive) { try $0.storages() }
    }

    public func list(_ folder: FolderRef) async throws -> [FileEntry] {
        try await worker(folder.deviceID).perform(.interactive) {
            try $0.listFolder(storageID: folder.storageID, folderID: folder.folderID)
        }
    }

    public func createFolder(named name: String, in folder: FolderRef) async throws -> FileEntry {
        try await worker(folder.deviceID).perform(.interactive) {
            try $0.createFolder(name: name, storageID: folder.storageID, parentID: folder.folderID)
        }
    }

    public func rename(objectID: UInt32, deviceID: DeviceID, to newName: String) async throws {
        try await worker(deviceID).perform(.interactive) { try $0.rename(objectID: objectID, to: newName) }
    }

    public func delete(objectID: UInt32, deviceID: DeviceID) async throws {
        try await worker(deviceID).perform(.interactive) { try $0.delete(objectID: objectID) }
    }

    public func download(jobID: UUID, entry: FileEntry, deviceID: DeviceID, into directory: URL) async throws -> URL {
        let reporter = ProgressReporter(jobID: jobID, registry: cancellations, handler: eventHandler)
        defer { cancellations.clear(jobID) }
        return try await worker(deviceID).perform(.transfer) { device in
            try reporter.checkCancelled()
            return try Transfers.download(entry, from: device, into: directory) { reporter.report(done: $0, total: $1) }
        }
    }

    public func upload(jobID: UUID, fileURL: URL, to folder: FolderRef) async throws -> FileEntry {
        let reporter = ProgressReporter(jobID: jobID, registry: cancellations, handler: eventHandler)
        defer { cancellations.clear(jobID) }
        return try await worker(folder.deviceID).perform(.transfer) { device in
            try reporter.checkCancelled()
            return try Transfers.upload(fileURL, to: device, storageID: folder.storageID, parentID: folder.folderID) {
                reporter.report(done: $0, total: $1)
            }
        }
    }

    public func cancel(jobID: UUID) {
        cancellations.cancel(jobID)
    }

    private func worker(_ id: DeviceID) throws -> DeviceWorker {
        if let worker = workers[id] { return worker }
        if case .unavailable(let error)? = infos[id]?.state { throw error }
        throw MTPError.deviceDisconnected
    }

    private func sortedDevices() -> [DeviceInfo] {
        infos.values.sorted { $0.id < $1.id }
    }

    private func emit(_ event: ServiceEvent) {
        eventHandler?(event)
    }
}

final class CancellationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled: Set<UUID> = []
    func cancel(_ id: UUID) { lock.withLock { _ = cancelled.insert(id) } }
    func isCancelled(_ id: UUID) -> Bool { lock.withLock { cancelled.contains(id) } }
    func clear(_ id: UUID) { lock.withLock { _ = cancelled.remove(id) } }
}

/// Used only on the DeviceWorker thread of the job it belongs to.
final class ProgressReporter: @unchecked Sendable {
    private let jobID: UUID
    private let registry: CancellationRegistry
    private let handler: (@Sendable (ServiceEvent) -> Void)?
    private var lastEmit: UInt64 = 0
    private static let interval: UInt64 = 100_000_000 // 10 updates per second

    init(jobID: UUID, registry: CancellationRegistry, handler: (@Sendable (ServiceEvent) -> Void)?) {
        self.jobID = jobID
        self.registry = registry
        self.handler = handler
    }

    func checkCancelled() throws {
        if registry.isCancelled(jobID) { throw MTPError.cancelled }
    }

    func report(done: UInt64, total: UInt64) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        if done >= total || now - lastEmit >= Self.interval {
            lastEmit = now
            handler?(.progress(jobID: jobID, done: done, total: total))
        }
        return !registry.isCancelled(jobID)
    }
}
