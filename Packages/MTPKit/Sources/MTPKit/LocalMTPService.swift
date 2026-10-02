import Foundation

public actor LocalMTPService: MTPService {
    private let provider: any DeviceProvider
    private var workers: [DeviceID: DeviceWorker] = [:]
    private var infos: [DeviceID: DeviceInfo] = [:]
    /// In-flight opens: device -> epoch of the restart generation that started the open.
    private var opening: [DeviceID: Int] = [:]
    /// Bumped whenever a rescan sees the device absent, so a handle opened before an unplug/replug is stale.
    private var generations: [DeviceID: Int] = [:]
    /// Transport key -> the device's own identity (e.g. "serial-…"), stable across unplug/replug.
    /// Internal maps stay keyed by transport key; `DeviceInfo.id` and all public calls use the identity.
    private var publicIDs: [DeviceID: DeviceID] = [:]
    /// Bumped by `restart()`; opens started in an older epoch are discarded.
    private var epoch = 0
    private var lastAttached: Set<DeviceID> = []
    /// Transport keys the user ejected; skipped by scans until a scan sees them unplugged.
    private var ejected: Set<DeviceID> = []
    /// The first scan is shared: concurrent first callers all await the same task.
    private var firstScan: Task<Void, Never>?
    private var hasScanned = false
    private var eventHandler: (@Sendable (ServiceEvent) -> Void)?
    private let cancellations = CancellationRegistry()
    private let log: DiagnosticLog

    public init(provider: any DeviceProvider, log: DiagnosticLog = .shared) {
        self.provider = provider
        self.log = log
    }

    public var hasUnavailableDevices: Bool {
        infos.values.contains { $0.state != .ready }
    }

    public func setEventHandler(_ handler: @escaping @Sendable (ServiceEvent) -> Void) {
        eventHandler = handler
    }

    public func devices() async throws -> [DeviceInfo] {
        await ensureScanned()
        return sortedDevices()
    }

    public func rescan() async {
        await performScan()
    }

    /// Joins the shared first scan; concurrent first callers all await the same task.
    private func ensureScanned() async {
        // Join an in-flight first scan even if an explicit rescan already set `hasScanned`.
        if let firstScan { await firstScan.value; return }
        guard !hasScanned else { return }
        let scan = Task { await self.performScan() }
        firstScan = scan
        await scan.value
    }

    private func performScan() async {
        let attached = provider.attachedDevices()
        lastAttached = Set(attached.map(\.id))
        ejected.formIntersection(lastAttached) // unplugged phones come back next time they're attached

        for id in Set(infos.keys).union(opening.keys) where !lastAttached.contains(id) {
            generations[id, default: 0] += 1
            log.record("Device removed", category: "device")
            workers.removeValue(forKey: id)?.shutdown(reason: .deviceDisconnected)
            infos[id] = nil
            publicIDs[id] = nil
        }

        for device in attached where workers[device.id] == nil && opening[device.id] == nil && !ejected.contains(device.id) {
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
                && !ejected.contains(device.id)
            switch result {
            case .success(let opened):
                guard current else { opened.close(); continue }
                let identity = opened.info.id
                let taken = publicIDs.contains { $0.key != device.id && $0.value == identity }
                let publicID = taken ? device.id : identity
                publicIDs[device.id] = publicID
                workers[device.id] = DeviceWorker(device: opened, name: device.model)
                infos[device.id] = DeviceInfo(id: publicID, manufacturer: opened.info.manufacturer,
                                              model: opened.info.model, state: opened.info.state,
                                              session: UUID(), osVersion: opened.info.osVersion)
                log.record("Opened \(opened.info.manufacturer) \(opened.info.model) (Android \(opened.info.osVersion ?? "?"))",
                           category: "device")
            case .failure(let error):
                guard current else { continue }
                // Rescans repeat every few seconds while a phone is locked; log only when the state changes.
                let changed = infos[device.id]?.state != .unavailable(error)
                infos[device.id] = DeviceInfo(id: device.id, manufacturer: device.manufacturer,
                                              model: device.model, state: .unavailable(error))
                if changed { log.record("Open failed for \(device.model): \(error.logDescription)", category: "device") }
            }
        }
        hasScanned = true
        emit(.devicesChanged(sortedDevices()))
    }

    public func restart() async {
        log.record("Service restarted", category: "service")
        for worker in workers.values { worker.shutdown(reason: .serviceInterrupted) }
        workers.removeAll()
        infos.removeAll()
        publicIDs.removeAll()
        epoch += 1
        opening.removeAll()
        emit(.interrupted)
        await performScan()
    }

    public func ejectDevice(_ deviceID: DeviceID) async throws {
        // Don't join a first scan that is still opening phones: an eject must be able to cancel that very open.
        if firstScan == nil { await ensureScanned() }
        let key = key(for: deviceID)
        guard infos[key] != nil || opening[key] != nil else { throw MTPError.deviceDisconnected }
        ejected.insert(key)
        workers.removeValue(forKey: key)?.shutdown(reason: .deviceDisconnected)
        infos[key] = nil
        publicIDs[key] = nil
        log.record("Device ejected", category: "device")
        emit(.devicesChanged(sortedDevices()))
    }

    public func releaseDevice(_ deviceID: DeviceID) async throws {
        var signalled = false
        do {
            try await attemptRelease(deviceID, signalled: &signalled)
            log.record("Release requested: signalled=\(signalled), result=ok", category: "device")
        } catch {
            log.record("Release requested: signalled=\(signalled), result=\(MTPError.from(error).logDescription)",
                       category: "device")
            throw error
        }
    }

    private func attemptRelease(_ deviceID: DeviceID, signalled: inout Bool) async throws {
        await ensureScanned()
        // Only a phone that is actually held by Image Capture may cause a process to be signalled.
        switch infos[key(for: deviceID)]?.state {
        case nil: throw MTPError.deviceDisconnected
        case .ready?: return
        case .unavailable(let error)? where error != .claimedByOtherProcess: throw error
        default: break
        }
        let provider = self.provider
        let released = await Task.detached { provider.releaseClaims() }.value
        signalled = released
        guard released else { throw MTPError.claimedByOtherProcess }
        try? await Task.sleep(for: .milliseconds(500)) // give the agent a moment to let go of the interface
        await rescan()
        switch infos[key(for: deviceID)]?.state {
        case nil: throw MTPError.deviceDisconnected
        case .unavailable(.claimedByOtherProcess)?: throw MTPError.claimedByOtherProcess
        default: break
        }
    }

    /// Reads only the Sendable log, so a wedged service actor can't block Copy Diagnostics.
    public nonisolated func diagnostics() async throws -> [String] {
        log.snapshot()
    }

    public func storages(deviceID: DeviceID) async throws -> [StorageInfo] {
        try await worker(deviceID, scanning: true).perform(.interactive) { try $0.storages() }
    }

    public func list(_ folder: FolderRef) async throws -> [FileEntry] {
        let worker = try await worker(folder.deviceID, scanning: true)
        try checkSession(folder)
        return try await worker.perform(.interactive) {
            try $0.listFolder(storageID: folder.storageID, folderID: folder.folderID)
        }
    }

    public func thumbnail(objectID: UInt32, in folder: FolderRef) async throws -> Data? {
        let worker = try await worker(folder.deviceID, scanning: true)
        try checkSession(folder)
        return try await worker.perform(.background) { try $0.thumbnail(objectID: objectID) }
    }

    public func createFolder(named name: String, in folder: FolderRef) async throws -> FileEntry {
        let worker = try await worker(folder.deviceID, scanning: true)
        try checkSession(folder)
        return try await worker.perform(.interactive) {
            try $0.createFolder(name: name, storageID: folder.storageID, parentID: folder.folderID)
        }
    }

    public func rename(_ entry: FileEntry, in folder: FolderRef, to newName: String) async throws {
        let worker = try await worker(folder.deviceID, scanning: true)
        try checkSession(folder)
        try await worker.perform(.interactive) { device in
            try Transfers.verify(entry, on: device)
            try device.rename(objectID: entry.objectID, to: newName)
        }
    }

    public func delete(_ entry: FileEntry, in folder: FolderRef) async throws {
        let worker = try await worker(folder.deviceID, scanning: true)
        try checkSession(folder)
        try await worker.perform(.interactive) { device in
            try Transfers.verify(entry, on: device)
            try device.delete(objectID: entry.objectID)
        }
    }

    public func download(jobID: UUID, entry: FileEntry, deviceID: DeviceID, into directory: URL) async throws -> URL {
        let reporter = ProgressReporter(jobID: jobID, registry: cancellations, handler: eventHandler)
        defer { cancellations.clear(jobID) }
        return try await worker(deviceID, scanning: true).perform(.transfer) { device in
            try reporter.checkCancelled()
            return try Transfers.download(entry, from: device, into: directory) { reporter.report(done: $0, total: $1) }
        }
    }

    public func upload(jobID: UUID, fileURL: URL, to folder: FolderRef,
                       conflict: ConflictResolution) async throws -> FileEntry {
        let reporter = ProgressReporter(jobID: jobID, registry: cancellations, handler: eventHandler)
        defer { cancellations.clear(jobID) }
        let worker = try await worker(folder.deviceID, scanning: true)
        try checkSession(folder)
        return try await worker.perform(.transfer) { device in
            try reporter.checkCancelled()
            return try Transfers.upload(fileURL, to: device, storageID: folder.storageID, parentID: folder.folderID,
                                        conflict: conflict) {
                reporter.report(done: $0, total: $1)
            }
        }
    }

    public func cancel(jobID: UUID) {
        cancellations.cancel(jobID)
    }

    /// With `scanning`, a service that has never scanned (e.g. a freshly relaunched helper) scans first.
    private func worker(_ id: DeviceID, scanning: Bool) async throws -> DeviceWorker {
        if scanning { await ensureScanned() }
        return try worker(id)
    }

    /// Public device identity -> transport key (the identity itself when it has no mapping).
    private func key(for id: DeviceID) -> DeviceID {
        publicIDs.first { $0.value == id }?.key ?? id
    }

    private func worker(_ id: DeviceID) throws -> DeviceWorker {
        let key = key(for: id)
        if let worker = workers[key] { return worker }
        if case .unavailable(let error)? = infos[key]?.state { throw error }
        throw MTPError.deviceDisconnected
    }

    /// Refuses a folder from an earlier connection: Android renumbers objects on reconnect.
    private func checkSession(_ folder: FolderRef) throws {
        guard let expected = folder.session else { return }
        guard infos[key(for: folder.deviceID)]?.session == expected else { throw MTPError.phoneReconnected }
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
