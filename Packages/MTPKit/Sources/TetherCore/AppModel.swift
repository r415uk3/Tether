import Foundation
import Observation
import MTPKit

@MainActor
@Observable
public final class AppModel {
    public let devices: DeviceStore
    public let transfers: TransferQueue
    public let thumbnails: ThumbnailStore
    public let previews: PreviewCache
    @ObservationIgnored private let service: any MTPService
    @ObservationIgnored private let log: DiagnosticLog
    /// How long Copy Diagnostics waits for the helper's log before reporting it unavailable.
    public var diagnosticsTimeout: Duration = .seconds(2)

    public init(service: any MTPService,
                thumbnailDirectory: URL? = ThumbnailStore.defaultDirectory,
                previewDirectory: URL = PreviewCache.defaultDirectory,
                log: DiagnosticLog = .shared) {
        self.service = service
        self.log = log
        devices = DeviceStore(service: service, log: log)
        transfers = TransferQueue(service: service, log: log)
        thumbnails = ThumbnailStore(service: service, directory: thumbnailDirectory)
        previews = PreviewCache(service: service, directory: previewDirectory)
        // Previews download on the same serial device worker as transfers, so they also make it busy.
        devices.isDeviceBusy = { [weak transfers, weak previews] id in
            transfers?.jobs.contains { $0.deviceID == id && $0.state == .running } == true
                || previews?.isDownloading(deviceID: id) == true
        }
        devices.onDeviceBecameReady = { [weak transfers] id in transfers?.deviceReconnected(id) }
        transfers.onJobFinished = { [weak store = devices] job in
            guard case .upload(_, let folder, _) = job.kind, let store else { return }
            Task {
                await store.refresh(folder)
                await store.loadStorages(folder.deviceID)
            }
        }
    }

    public func activeTransferCount(for deviceID: DeviceID) -> Int {
        transfers.jobs.filter { $0.isActive && $0.deviceID == deviceID }.count
    }

    /// Stops this phone's transfers and previews, then ejects it.
    public func eject(_ deviceID: DeviceID) async -> MTPError? {
        transfers.cancelAll(deviceID: deviceID)
        // Cancels every preview download, not just this phone's: only one Quick Look panel exists.
        previews.cancelAll()
        return await devices.eject(deviceID)
    }

    /// How long the window waits for the first device list before showing the no-phone guide.
    public var initialLoadTimeout: Duration = .seconds(10)

    public func start() async {
        await service.setEventHandler { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        let timeout = initialLoadTimeout
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.devices.markLoaded()
        }
        transfers.startWatchdog()
        await devices.reloadDevices()
        timer.cancel()
    }

    func handle(_ event: ServiceEvent) {
        switch event {
        case .devicesChanged(let list):
            devices.apply(list)
        case .progress(let attempt, let done, let total):
            if !transfers.updateProgress(attempt: attempt, done: done, total: total) {
                let device = previews.deviceID(forPreviewJob: attempt)
                if previews.updateProgress(jobID: attempt, done: done, total: total), let device {
                    transfers.noteDeviceActivity(device) // the preview shares the device's worker with queued transfers
                }
            }
        case .interrupted:
            Task { await devices.reloadDevices() }
        }
    }

    /// The helper's log, or nil if it errors or doesn't answer within `diagnosticsTimeout`.
    private func helperLog() async -> [String]? {
        let service = self.service
        let timeout = diagnosticsTimeout
        // Unstructured tasks: a task group would wait for a call that ignores cancellation.
        let race = Race<[String]?>()
        return await withCheckedContinuation { continuation in
            race.install(continuation)
            Task { race.finish(try? await service.diagnostics()) }
            Task { try? await Task.sleep(for: timeout); race.finish(nil) }
        }
    }

    public func diagnosticsReport(appVersion: String) async -> String {
        let helperLog = await helperLog()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return DiagnosticsReport.make(
            appVersion: appVersion,
            macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            devices: devices.devices,
            appLog: log.snapshot(),
            helperLog: helperLog)
    }
}

/// Delivers the first of several results to a continuation installed before any result is produced.
private final class Race<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    func install(_ continuation: CheckedContinuation<T, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func finish(_ value: T) {
        let continuation = lock.withLock { () -> CheckedContinuation<T, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
    }
}
