import Foundation
import Observation
import MTPKit

@MainActor
@Observable
public final class DeviceStore {
    public struct Listing: Equatable, Sendable {
        public var entries: [FileEntry]
        public var isUpdating: Bool
        public var error: MTPError?
    }

    public private(set) var devices: [DeviceInfo] = []
    public private(set) var storages: [DeviceID: [StorageInfo]] = [:]
    public private(set) var storageErrors: [DeviceID: MTPError] = [:]
    /// Why the last Release of a phone failed; cleared on the next attempt, on success, and when the phone leaves the claimed state.
    public private(set) var releaseErrors: [DeviceID: MTPError] = [:]
    /// Phones with a Release in flight; a second request for the same phone is ignored.
    public private(set) var releasing: Set<DeviceID> = []
    public private(set) var listings: [FolderRef: Listing] = [:]
    public private(set) var hasLoaded = false
    public var listTimeout: Duration = .seconds(15)

    /// Reports whether a transfer is running on the device. A listing then queues behind it, so it must not
    /// be timed out (which would restart the service and kill the transfer); the transfer watchdog covers hangs.
    @ObservationIgnored public var isDeviceBusy: (@MainActor (DeviceID) -> Bool)?

    /// Called for each device that has just become ready (first seen, or back after an unplug).
    @ObservationIgnored public var onDeviceBecameReady: (@MainActor (DeviceID) -> Void)?

    @ObservationIgnored private let service: any MTPService
    /// Bumped at the start of every refresh; only the latest refresh of a folder may write its result.
    @ObservationIgnored private var generations: [FolderRef: Int] = [:]

    @ObservationIgnored private let log: DiagnosticLog

    public init(service: any MTPService, log: DiagnosticLog = .shared) {
        self.service = service
        self.log = log
    }

    /// Asks the service to free a phone held by Image Capture; returns the error if it stays held.
    /// Reloads the device list either way. After a successful release the device's ID changes from its
    /// transport key to its serial identity, so callers must not keep using the old ID.
    public func release(_ id: DeviceID) async -> MTPError? {
        guard releasing.insert(id).inserted else { return nil }
        defer { releasing.remove(id) }
        releaseErrors[id] = nil
        var failure: MTPError?
        do {
            try await service.releaseDevice(id)
        } catch {
            failure = MTPError.from(error)
        }
        await reloadDevices()
        releaseErrors[id] = failure
        return failure
    }

    /// Closes Tether's connection to the phone; it disappears from the list until it is unplugged and plugged in again.
    public func eject(_ id: DeviceID) async -> MTPError? {
        var failure: MTPError?
        do { try await service.ejectDevice(id) } catch { failure = MTPError.from(error) }
        await reloadDevices()
        return failure
    }

    /// Ends the launch spinner even if the helper never answered; the no-phone guide shows until devices arrive.
    public func markLoaded() { hasLoaded = true }

    public func reloadDevices() async {
        defer { hasLoaded = true }
        // A transient failure must not wipe known devices, storages and cached listings.
        guard let list = try? await service.devices() else { return }
        apply(list)
    }

    public func session(for deviceID: DeviceID) -> UUID? {
        devices.first { $0.id == deviceID && $0.state == .ready }?.session
    }

    public func apply(_ newDevices: [DeviceInfo]) {
        hasLoaded = true
        let before = Dictionary(devices.filter { $0.state == .ready }.map { ($0.id, $0.session) },
                                uniquingKeysWith: { first, _ in first })
        let now = Dictionary(newDevices.filter { $0.state == .ready }.map { ($0.id, $0.session) },
                             uniquingKeysWith: { first, _ in first })
        // Newly ready, or ready again on a new connection (handles from the old one are meaningless).
        let fresh = Set(now.keys.filter { id in
            guard let old = before[id] else { return true }
            return old != now[id]!
        })
        devices = newDevices
        storages = storages.filter { now[$0.key] != nil && !fresh.contains($0.key) }
        storageErrors = storageErrors.filter { now[$0.key] != nil && !fresh.contains($0.key) }
        let claimed = Set(newDevices.filter { $0.state == .unavailable(.claimedByOtherProcess) }.map(\.id))
        releaseErrors = releaseErrors.filter { claimed.contains($0.key) }
        listings = listings.filter { key, _ in now[key.deviceID] != nil && !fresh.contains(key.deviceID) }
        for id in fresh {
            onDeviceBecameReady?(id)
            Task { await loadStorages(id) }
        }
    }

    public func loadStorages(_ id: DeviceID) async {
        do {
            let list = try await service.storages(deviceID: id)
            guard isReady(id) else { return }
            storages[id] = list
            storageErrors[id] = nil
        } catch {
            guard isReady(id) else { return }
            let mtpError = MTPError.from(error)
            storageErrors[id] = mtpError
            log.record("Storage list failed: \(mtpError.logDescription)", category: "browse")
        }
    }

    /// Retries after a failure; clears the error first so the UI shows progress.
    public func retryStorages(_ id: DeviceID) async {
        storageErrors[id] = nil
        await loadStorages(id)
    }

    public func storage(for folder: FolderRef) -> StorageInfo? {
        storages[folder.deviceID]?.first { $0.id == folder.storageID }
    }

    public func refresh(_ folder: FolderRef) async {
        guard isKnown(folder.deviceID) else { listings[folder] = nil; return }
        let generation = (generations[folder] ?? 0) + 1
        generations[folder] = generation

        var listing = listings[folder] ?? Listing(entries: [], isUpdating: true, error: nil)
        listing.isUpdating = true
        listings[folder] = listing

        let service = self.service
        let result: Result<[FileEntry], MTPError>
        do {
            if isDeviceBusy?(folder.deviceID) == true {
                result = .success(try await service.list(folder))
            } else {
                result = .success(try await withTimeout(listTimeout, onTimeout: { await service.restart() }) {
                    try await service.list(folder)
                })
            }
        } catch {
            result = .failure(MTPError.from(error))
        }

        guard generations[folder] == generation else { return }
        // The phone reconnected while this ran: `apply` already dropped this folder's state.
        if let folderSession = folder.session, folderSession != session(for: folder.deviceID) {
            listings[folder] = nil
            generations[folder] = nil
            return
        }
        let deviceAvailable = result.isTimeout ? isKnown(folder.deviceID) : isReady(folder.deviceID)
        guard deviceAvailable else { listings[folder] = nil; return }
        switch result {
        case .success(let entries):
            listings[folder] = Listing(entries: entries, isUpdating: false, error: nil)
        case .failure(let error):
            log.record("Listing failed: \(error.logDescription)", category: "browse")
            listings[folder] = Listing(entries: listings[folder]?.entries ?? [], isUpdating: false, error: error)
        }
    }

    public func createFolder(named name: String, in folder: FolderRef) async throws -> FileEntry {
        let entry = try await service.createFolder(named: name, in: folder)
        await refresh(folder)
        return entry
    }

    public func rename(_ entry: FileEntry, in folder: FolderRef, to newName: String) async throws {
        do { try await service.rename(entry, in: folder, to: newName) }
        catch { await refresh(folder); throw error }
        await refresh(folder)
    }

    public func delete(_ entries: [FileEntry], in folder: FolderRef) async throws {
        do {
            for entry in entries { try await service.delete(entry, in: folder) }
        } catch {
            await refresh(folder)
            throw error
        }
        await refresh(folder)
    }

    private func isKnown(_ id: DeviceID) -> Bool {
        devices.contains { $0.id == id }
    }

    private func isReady(_ id: DeviceID) -> Bool {
        devices.contains { $0.id == id && $0.state == .ready }
    }
}

private extension Result where Failure == MTPError {
    /// A timeout restarts the service, which briefly removes devices; keep the error visible anyway.
    var isTimeout: Bool { if case .failure(.timeout) = self { true } else { false } }
}
