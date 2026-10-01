import Foundation
import Observation
import MTPKit

@MainActor
@Observable
public final class TransferQueue {
    public enum Kind: Equatable, Sendable {
        case download(FileEntry, deviceID: DeviceID, directory: URL)
        case upload(URL, folder: FolderRef, conflict: ConflictResolution)
    }

    public enum State: Equatable, Sendable {
        case queued, running, finished(URL?), failed(MTPError), cancelled
    }

    public struct Job: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let kind: Kind
        public internal(set) var state: State = .queued
        public internal(set) var done: UInt64 = 0
        public internal(set) var total: UInt64 = 0
        /// Identifies one run of the job to the service; changes on retry.
        var attempt = UUID()
        var lastActivity = ContinuousClock.now
        /// An upload that predates a reconnect of its device: its folder handle may now name another object.
        var isStale = false

        public var name: String {
            switch kind {
            case .download(let entry, _, _): entry.name
            case .upload(let url, _, _): url.lastPathComponent
            }
        }

        public var deviceID: DeviceID {
            switch kind {
            case .download(_, let deviceID, _): deviceID
            case .upload(_, let folder, _): folder.deviceID
            }
        }

        public var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
        public var isActive: Bool { state == .queued || state == .running }
    }

    public typealias Completion = @MainActor (Result<URL?, MTPError>) -> Void

    public private(set) var jobs: [Job] = []
    public var stallTimeout: Duration = .seconds(30)
    @ObservationIgnored public var onJobFinished: (@MainActor (Job) -> Void)?

    @ObservationIgnored private let service: any MTPService
    @ObservationIgnored private var completions: [UUID: Completion] = [:]
    @ObservationIgnored private var restartsInFlight = 0
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    @ObservationIgnored private let log: DiagnosticLog

    public init(service: any MTPService, log: DiagnosticLog = .shared) {
        self.service = service
        self.log = log
    }

    public var hasActiveJobs: Bool { jobs.contains { $0.isActive } }

    @discardableResult
    public func enqueueDownload(_ entry: FileEntry, deviceID: DeviceID, into directory: URL,
                                completion: Completion? = nil) -> UUID {
        enqueue(.download(entry, deviceID: deviceID, directory: directory), completion: completion)
    }

    @discardableResult
    public func enqueueUpload(_ url: URL, to folder: FolderRef, conflict: ConflictResolution = .fail) -> UUID {
        enqueue(.upload(url, folder: folder, conflict: conflict), completion: nil)
    }

    public func cancel(_ id: UUID) {
        guard let i = index(id) else { return }
        switch jobs[i].state {
        case .queued:
            finish(i, .cancelled)
        case .running:
            let attempt = jobs[i].attempt
            Task { await service.cancel(jobID: attempt) }
        default:
            break
        }
    }

    public func retry(_ id: UUID) {
        guard let i = index(id) else { return }
        switch jobs[i].state {
        case .failed, .cancelled:
            jobs[i].state = .queued
            jobs[i].done = 0
            jobs[i].attempt = UUID()
            pump()
        default:
            break
        }
    }

    /// The device became ready again (e.g. after a replug). Android numbers objects afresh for every USB
    /// connection, so uploads that were waiting or that ended earlier may target a different folder now;
    /// they fail instead of running. Downloads re-check their entry on the device, so they are left alone.
    public func deviceReconnected(_ id: DeviceID) {
        for i in jobs.indices where jobs[i].deviceID == id {
            guard case .upload = jobs[i].kind else { continue }
            if case .finished = jobs[i].state { continue }
            jobs[i].isStale = true // a running upload is still on the old connection and will fail
        }
    }

    @discardableResult
    public func updateProgress(attempt: UUID, done: UInt64, total: UInt64) -> Bool {
        // No state check: the final event may arrive just after the job finished.
        guard let i = jobs.firstIndex(where: { $0.attempt == attempt }) else { return false }
        jobs[i].done = max(jobs[i].done, done)
        jobs[i].total = total
        jobs[i].lastActivity = .now
        return true
    }

    public func startWatchdog(interval: Duration = .seconds(5)) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await self.checkForStalls(now: .now)
            }
        }
    }

    /// Restarts the service when a running job has made no progress for `stallTimeout`.
    public func checkForStalls(now: ContinuousClock.Instant = .now) async {
        let stalled = jobs.contains { $0.state == .running && now - $0.lastActivity > stallTimeout }
        guard stalled else { return }
        for i in jobs.indices where jobs[i].state == .running { jobs[i].lastActivity = now }
        restartsInFlight += 1
        await service.restart()
        restartsInFlight -= 1
        pump()
    }

    // MARK: Internals

    private func enqueue(_ kind: Kind, completion: Completion?) -> UUID {
        let job = Job(id: UUID(), kind: kind)
        jobs.append(job)
        if let completion { completions[job.id] = completion }
        pump()
        return job.id
    }

    private func index(_ id: UUID) -> Int? { jobs.firstIndex { $0.id == id } }

    private func pump() {
        guard restartsInFlight == 0 else { return } // the device is reopening; queued jobs would fail as disconnected
        var busy = Set(jobs.filter { $0.state == .running }.map(\.deviceID))
        for i in jobs.indices where jobs[i].state == .queued && !busy.contains(jobs[i].deviceID) {
            busy.insert(jobs[i].deviceID)
            jobs[i].state = .running
            jobs[i].lastActivity = .now
            let job = jobs[i]
            Task { await run(job) }
        }
    }

    private func run(_ job: Job) async {
        let result: Result<URL?, MTPError>
        do {
            if job.isStale { throw Self.staleUploadError }
            switch job.kind {
            case .download(let entry, let deviceID, let directory):
                result = .success(try await service.download(jobID: job.attempt, entry: entry,
                                                             deviceID: deviceID, into: directory))
            case .upload(let url, let folder, let conflict):
                _ = try await service.upload(jobID: job.attempt, fileURL: url, to: folder, conflict: conflict)
                result = .success(nil)
            }
        } catch {
            result = .failure(MTPError.from(error))
        }
        guard let i = index(job.id), jobs[i].attempt == job.attempt else { return }
        switch result {
        case .success(let url): finish(i, .finished(url))
        case .failure(.cancelled): finish(i, .cancelled)
        case .failure(let error): finish(i, .failed(error))
        }
        pump()
    }

    private static var staleUploadError: MTPError {
        .underlying(code: -6, message: String(
            localized: "The phone was reconnected, so this folder may have changed. Upload the item again."))
    }

    private func finish(_ i: Int, _ state: State) {
        jobs[i].state = state
        if case .finished = state { jobs[i].done = max(jobs[i].done, jobs[i].total) }
        let job = jobs[i]
        if case .failed(let error) = state {
            // `total` stays 0 when the job failed before any progress; fall back to the known size.
            let (kind, size): (String, UInt64) = switch job.kind {
            case .download(let entry, _, _): ("download", job.total > 0 ? job.total : entry.size)
            case .upload(let url, _, _):
                ("upload", job.total > 0 ? job.total
                    : ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(UInt64.init) ?? 0))
            }
            log.record("Transfer failed (\(kind), \(size) bytes): \(error.logDescription)", category: "transfer")
        }
        if let completion = completions.removeValue(forKey: job.id) {
            switch state {
            case .finished(let url): completion(.success(url))
            case .failed(let error): completion(.failure(error))
            default: completion(.failure(.cancelled))
            }
        }
        onJobFinished?(job)
    }
}
