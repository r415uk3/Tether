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

    public func apply(_ newDevices: [DeviceInfo]) {
        let readyBefore = Set(devices.filter { $0.state == .ready }.map(\.id))
        let readyNow = Set(newDevices.filter { $0.state == .ready }.map(\.id))
        devices = newDevices
        storages = storages.filter { readyNow.contains($0.key) }
        listings = listings.filter { readyNow.contains($0.key.deviceID) }
        for id in readyNow.subtracting(readyBefore) {
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
            result = .success(try await withTimeout(listTimeout, onTimeout: { await service.restart() }) {
                try await service.list(folder)
            })
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
        do { try await service.rename(objectID: entry.objectID, deviceID: folder.deviceID, to: newName) }
        catch { await refresh(folder); throw error }
        await refresh(folder)
    }

    public func delete(_ entries: [FileEntry], in folder: FolderRef) async throws {
        do {
            for entry in entries { try await service.delete(objectID: entry.objectID, deviceID: folder.deviceID) }
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
