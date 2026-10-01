import Foundation
import Observation
import MTPKit

@MainActor
@Observable
public final class AppModel {
    public let devices: DeviceStore
    public let transfers: TransferQueue
    @ObservationIgnored private let service: any MTPService

    public init(service: any MTPService) {
        self.service = service
        devices = DeviceStore(service: service)
        transfers = TransferQueue(service: service)
        transfers.onJobFinished = { [weak store = devices] job in
            guard case .upload(_, let folder) = job.kind, let store else { return }
            Task {
                await store.refresh(folder)
                await store.loadStorages(folder.deviceID)
            }
        }
    }

    public func start() async {
        await service.setEventHandler { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        await devices.reloadDevices()
        transfers.startWatchdog()
    }

    func handle(_ event: ServiceEvent) {
        switch event {
        case .devicesChanged(let list):
            devices.apply(list)
        case .progress(let attempt, let done, let total):
            transfers.updateProgress(attempt: attempt, done: done, total: total)
        case .interrupted:
            Task { await devices.reloadDevices() }
        }
    }
}
