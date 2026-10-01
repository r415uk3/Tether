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
    public private(set) var listings: [FolderRef: Listing] = [:]
    public var listTimeout: Duration = .seconds(15)

    /// Reports whether a transfer is running on the device. A listing then queues behind it, so it must not
    /// be timed out (which would restart the service and kill the transfer); the transfer watchdog covers hangs.
    @ObservationIgnored public var isDeviceBusy: (@MainActor (DeviceID) -> Bool)?

    /// Called for each device that has just become ready (first seen, or back after an unplug).
    @ObservationIgnored public var onDeviceBecameReady: (@MainActor (DeviceID) -> Void)?

    @ObservationIgnored private let service: any MTPService
    /// Bumped at the start of every refresh; only the latest refresh of a folder may write its result.
    @ObservationIgnored private var generations: [FolderRef: Int] = [:]

    public init(service: any MTPService) {
        self.service = service
    }

    public func reloadDevices() async {
        // A transient failure must not wipe known devices, storages and cached listings.
        guard let list = try? await service.devices() else { return }
        apply(list)
    }

    public func session(for deviceID: DeviceID) -> UUID? {
        devices.first { $0.id == deviceID && $0.state == .ready }?.session
    }

    public func apply(_ newDevices: [DeviceInfo]) {
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
        listings = listings.filter { key, _ in now[key.deviceID] != nil && !fresh.contains(key.deviceID) }
        for id in fresh {
            onDeviceBecameReady?(id)
            Task { await loadStorages(id) }
        }
    }

    public func loadStorages(_ id: DeviceID) async {
        guard let list = try? await service.storages(deviceID: id), isReady(id) else { return }
        storages[id] = list
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
        let deviceAvailable = result.isTimeout ? isKnown(folder.deviceID) : isReady(folder.deviceID)
        guard deviceAvailable else { listings[folder] = nil; return }
        switch result {
        case .success(let entries):
            listings[folder] = Listing(entries: entries, isUpdating: false, error: nil)
        case .failure(let error):
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
