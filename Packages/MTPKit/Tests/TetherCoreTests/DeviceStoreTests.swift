import Foundation
import Testing
import MTPKit
@testable import TetherCore

@MainActor
@Suite struct DeviceStoreTests {
    let provider = FakeDeviceProvider()
    let device = FakeDevice(id: "p1")
    var folder: FolderRef { FolderRef(deviceID: "p1", storageID: 1) }

    private func makeStore() -> (DeviceStore, LocalMTPService) {
        provider.attach(device)
        let service = LocalMTPService(provider: provider)
        return (DeviceStore(service: service), service)
    }

    @Test func reloadLoadsDevicesAndStorages() async throws {
        let (store, _) = makeStore()
        await store.reloadDevices()
        #expect(store.devices.map(\.id) == ["p1"])
        try await eventually { store.storages["p1"]?.first?.id == 1 }
        #expect(store.storage(for: folder)?.name == "Internal shared storage")
    }

    @Test func storageLoadFailureIsRecordedAndRetried() async throws {
        let (store, _) = makeStore()
        device.inject(.fail(.deviceBusy)) // consumed by the first storages() call
        await store.reloadDevices()
        try await eventually { store.storageErrors["p1"] == .deviceBusy }
        #expect(store.storages["p1"] == nil)
        await store.loadStorages("p1")
        #expect(store.storageErrors["p1"] == nil)
        #expect(store.storages["p1"]?.isEmpty == false)
    }

    @Test func refreshCachesListing() async throws {
        device.addFolder("DCIM")
        let (store, _) = makeStore()
        await store.reloadDevices()
        await store.refresh(folder)
        #expect(store.listings[folder] == DeviceStore.Listing(entries: try device.listFolder(storageID: 1, folderID: FileEntry.rootID),
                                                              isUpdating: false, error: nil))
    }

    @Test func refreshKeepsCachedEntriesWhileUpdating() async throws {
        device.addFolder("DCIM")
        let (store, _) = makeStore()
        await store.reloadDevices()
        await store.refresh(folder)
        device.inject(.hang)
        let refreshing = Task { await store.refresh(folder) }
        try await eventually { store.listings[folder]?.isUpdating == true }
        #expect(store.listings[folder]?.entries.map(\.name) == ["DCIM"])
        device.releaseHang()
        await refreshing.value
        #expect(store.listings[folder]?.isUpdating == false)
    }

    @Test func sessionChangeDropsListingsAndCountsAsReconnect() async throws {
        let (store, _) = makeStore()
        await store.reloadDevices()
        await store.refresh(folder)
        #expect(store.listings[folder] != nil)
        var reconnected: [DeviceID] = []
        store.onDeviceBecameReady = { reconnected.append($0) }
        var info = try #require(store.devices.first)
        info.session = UUID()
        store.apply([info])
        #expect(store.listings.isEmpty)
        #expect(store.storages.isEmpty)
        #expect(reconnected == ["p1"])
        #expect(store.session(for: "p1") == info.session)
    }

    @Test func reapplyingTheSameSessionKeepsEverything() async throws {
        let (store, _) = makeStore()
        await store.reloadDevices()
        await store.refresh(folder)
        var reconnected: [DeviceID] = []
        store.onDeviceBecameReady = { reconnected.append($0) }
        store.apply(store.devices)
        #expect(reconnected.isEmpty)
        #expect(store.listings[folder] != nil)
    }

    @Test func oldSessionRefreshFinishingAfterReconnectDoesNotRecreateListing() async throws {
        provider.attach(device)
        let service = FlakyService(base: LocalMTPService(provider: provider))
        let store = DeviceStore(service: service)
        await store.reloadDevices()
        let old = FolderRef(deviceID: "p1", storageID: 1, session: store.session(for: "p1"))
        service.holdNextList = true
        let refresh = Task { await store.refresh(old) }
        try await eventually { service.heldListStarted }
        var info = try #require(store.devices.first)
        info.session = UUID()
        store.apply([info])
        service.releaseHeldList = true
        await refresh.value
        #expect(store.listings[old] == nil)
    }

    @Test func removedDeviceDropsListings() async throws {
        let (store, _) = makeStore()
        await store.reloadDevices()
        await store.refresh(folder)
        #expect(store.listings[folder] != nil)
        store.apply([])
        #expect(store.listings.isEmpty)
        #expect(store.storages.isEmpty)
    }

    @Test func hungListingTimesOutAndRestartsService() async throws {
        let (store, _) = makeStore()
        store.listTimeout = .milliseconds(200)
        await store.reloadDevices()
        device.inject(.hang)
        await store.refresh(folder)
        #expect(store.listings[folder]?.error == .timeout)
        #expect(store.listings[folder]?.isUpdating == false)
        #expect(provider.openCount("p1") == 2)
        device.releaseHang()
    }

    @Test func mutationsRefreshTheFolder() async throws {
        let (store, _) = makeStore()
        await store.reloadDevices()
        let created = try await store.createFolder(named: "New", in: folder)
        #expect(store.listings[folder]?.entries.map(\.name) == ["New"])
        try await store.rename(created, in: folder, to: "Renamed")
        #expect(store.listings[folder]?.entries.map(\.name) == ["Renamed"])
        try await store.delete(store.listings[folder]!.entries, in: folder)
        #expect(store.listings[folder]?.entries.isEmpty == true)
    }

    @Test func olderRefreshFinishingLastDoesNotOverwriteNewer() async throws {
        provider.attach(device)
        let service = FlakyService(base: LocalMTPService(provider: provider))
        let store = DeviceStore(service: service)
        await store.reloadDevices()
        service.holdNextList = true
        let older = Task { await store.refresh(folder) }
        try await eventually { service.heldListStarted }
        device.addFolder("New")
        await store.refresh(folder)
        #expect(store.listings[folder]?.entries.map(\.name) == ["New"])
        #expect(store.listings[folder]?.isUpdating == false)
        service.releaseHeldList = true
        await older.value
        #expect(store.listings[folder]?.entries.map(\.name) == ["New"])
        #expect(store.listings[folder]?.isUpdating == false)
    }

    @Test func refreshForUnknownDeviceLeavesNoListing() async throws {
        let (store, _) = makeStore()
        await store.reloadDevices()
        let ghost = FolderRef(deviceID: "ghost", storageID: 1)
        await store.refresh(ghost)
        #expect(store.listings[ghost] == nil)
    }

    @Test func timedOutRefreshForRemovedDeviceLeavesNoListing() async throws {
        let (store, _) = makeStore()
        store.listTimeout = .milliseconds(200)
        await store.reloadDevices()
        device.inject(.hang)
        let refreshing = Task { await store.refresh(folder) }
        try await eventually { store.listings[folder]?.isUpdating == true }
        store.apply([])
        await refreshing.value
        #expect(store.listings[folder] == nil)
        device.releaseHang()
    }

    @Test func reloadDevicesFailureKeepsExistingState() async throws {
        provider.attach(device)
        let service = FlakyService(base: LocalMTPService(provider: provider))
        let store = DeviceStore(service: service)
        await store.reloadDevices()
        await store.refresh(folder)
        service.failDevices = true
        await store.reloadDevices()
        #expect(store.devices.map(\.id) == ["p1"])
        #expect(store.listings[folder] != nil)
    }

    @Test func releaseReportsFailure() async throws {
        provider.attachUnavailable(AttachedDevice(id: "14-9", manufacturer: "S", model: "S25"), error: .claimedByOtherProcess)
        let (store, _) = makeStore()
        await store.reloadDevices()
        #expect(await store.release("14-9") == .claimedByOtherProcess)
    }

    @Test func releaseSucceedsAndListsDeviceReady() async throws {
        provider.attachClaimed(FakeDevice(id: "serial-A"), as: "14-4")
        let (store, _) = makeStore()
        await store.reloadDevices()
        #expect(await store.release("14-4") == nil)
        #expect(store.devices.first { $0.id == "serial-A" }?.state == .ready)
    }
}

private final class FlakyService: MTPService, @unchecked Sendable {
    let base: LocalMTPService
    private let lock = NSLock()
    private var _fail = false
    var failDevices: Bool {
        get { lock.withLock { _fail } }
        set { lock.withLock { _fail = newValue } }
    }
    private var _hold = false, _started = false, _release = false
    /// The next list() reads its result, then waits until releaseHeldList, so it finishes with stale data.
    var holdNextList: Bool {
        get { lock.withLock { _hold } }
        set { lock.withLock { _hold = newValue } }
    }
    var heldListStarted: Bool { lock.withLock { _started } }
    var releaseHeldList: Bool {
        get { lock.withLock { _release } }
        set { lock.withLock { _release = newValue } }
    }
    init(base: LocalMTPService) { self.base = base }
    func setEventHandler(_ handler: @escaping @Sendable (ServiceEvent) -> Void) async { await base.setEventHandler(handler) }
    func devices() async throws -> [DeviceInfo] {
        if failDevices { throw MTPError.serviceInterrupted }
        return try await base.devices()
    }
    func storages(deviceID: DeviceID) async throws -> [StorageInfo] { try await base.storages(deviceID: deviceID) }
    func releaseDevice(_ deviceID: DeviceID) async throws { try await base.releaseDevice(deviceID) }
    func diagnostics() async throws -> [String] { try await base.diagnostics() }
    func thumbnail(objectID: UInt32, in folder: FolderRef) async throws -> Data? {
        try await base.thumbnail(objectID: objectID, in: folder)
    }
    func list(_ folder: FolderRef) async throws -> [FileEntry] {
        let hold = lock.withLock { let h = _hold; _hold = false; return h }
        let result = try await base.list(folder)
        if hold {
            lock.withLock { _started = true }
            while !releaseHeldList { try await Task.sleep(for: .milliseconds(5)) }
        }
        return result
    }
    func download(jobID: UUID, entry: FileEntry, deviceID: DeviceID, into directory: URL) async throws -> URL {
        try await base.download(jobID: jobID, entry: entry, deviceID: deviceID, into: directory)
    }
    func upload(jobID: UUID, fileURL: URL, to folder: FolderRef, conflict: ConflictResolution) async throws -> FileEntry {
        try await base.upload(jobID: jobID, fileURL: fileURL, to: folder, conflict: conflict)
    }
    func createFolder(named name: String, in folder: FolderRef) async throws -> FileEntry {
        try await base.createFolder(named: name, in: folder)
    }
    func rename(_ entry: FileEntry, in folder: FolderRef, to newName: String) async throws {
        try await base.rename(entry, in: folder, to: newName)
    }
    func delete(_ entry: FileEntry, in folder: FolderRef) async throws { try await base.delete(entry, in: folder) }
    func cancel(jobID: UUID) async { await base.cancel(jobID: jobID) }
    func restart() async { await base.restart() }
}
