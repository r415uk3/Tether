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
}
