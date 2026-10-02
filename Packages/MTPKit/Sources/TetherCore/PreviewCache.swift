import Foundation
import MTPKit
import Observation

/// Downloads phone files for Quick Look into a private cache, one directory per item version.
@MainActor
@Observable
public final class PreviewCache {
    @ObservationIgnored private let service: any MTPService
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var ready: [ItemKey: URL] = [:]
    private struct InFlight {
        let task: Task<URL, Error>
        let jobID: UUID
        let token: UUID
        let deviceID: DeviceID
    }
    @ObservationIgnored private var inFlight: [ItemKey: InFlight] = [:]

    /// Fraction (0–1) of the most recently started preview download, or nil when none is running.
    public private(set) var progress: Double?
    @ObservationIgnored private var fractions: [UUID: Double] = [:]
    @ObservationIgnored private var newestJob: UUID?

    /// Routes a service progress event; returns false if the job isn't a preview download.
    @discardableResult
    public func updateProgress(jobID: UUID, done: UInt64, total: UInt64) -> Bool {
        guard fractions[jobID] != nil else { return false }
        fractions[jobID] = total == 0 ? 0 : min(1, Double(done) / Double(total))
        refreshProgress()
        return true
    }

    /// The device a running preview download occupies, or nil if `jobID` isn't a preview job.
    public func deviceID(forPreviewJob jobID: UUID) -> DeviceID? {
        inFlight.values.first { $0.jobID == jobID }?.deviceID
    }

    private func refreshProgress() {
        progress = newestJob.flatMap { fractions[$0] }
    }

    /// Cancels every preview download in flight (Quick Look closed or moved on); finished files stay cached.
    public func cancelAll() {
        cancel { _ in true }
    }

    /// Cancels only `deviceID`'s preview downloads (that phone is being ejected); other phones' keep going.
    public func cancelAll(deviceID: DeviceID) {
        cancel { $0.deviceID == deviceID }
    }

    private func cancel(where matches: (InFlight) -> Bool) {
        let service = self.service
        for (key, running) in inFlight where matches(running) {
            let jobID = running.jobID
            Task { await service.cancel(jobID: jobID) }
            inFlight[key] = nil
            fractions[jobID] = nil
            if newestJob == jobID { newestJob = nil }
        }
        refreshProgress()
    }

    public init(service: any MTPService, directory: URL = PreviewCache.defaultDirectory) {
        self.service = service
        self.directory = directory
    }

    public nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.tether.Tether/preview", isDirectory: true)
    }

    public func file(for entry: FileEntry, deviceID: DeviceID) async throws -> URL {
        let key = ItemKey(entry: entry, deviceID: deviceID)
        if let url = ready[key], FileManager.default.fileExists(atPath: url.path) { return url }
        if let running = inFlight[key] { return try await running.task.value }

        let folder = directory.appendingPathComponent(key.fileName, isDirectory: true)
        let service = self.service
        let jobID = UUID()
        let token = UUID()
        let task = Task { () throws -> URL in
            try? FileManager.default.removeItem(at: folder) // a leftover from an interrupted download
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return try await service.download(jobID: jobID, entry: entry, deviceID: deviceID, into: folder)
        }
        inFlight[key] = InFlight(task: task, jobID: jobID, token: token, deviceID: deviceID)
        fractions[jobID] = 0
        newestJob = jobID
        refreshProgress()
        defer {
            if inFlight[key]?.token == token { inFlight[key] = nil } // clear() may have replaced it
            fractions[jobID] = nil
            if newestJob == jobID { newestJob = nil }
            refreshProgress()
        }
        let url = try await task.value
        if inFlight[key]?.token == token { ready[key] = url }
        return url
    }

    /// True while a preview download occupies `deviceID` (it holds the device's serial worker).
    public func isDownloading(deviceID: DeviceID) -> Bool {
        inFlight.values.contains { $0.deviceID == deviceID }
    }

    public func clear() {
        ready.removeAll()
        cancelAll()
        Self.clear(directory: directory)
    }

    /// Removes the cache directory; safe from any thread (used on quit).
    public nonisolated static func clear(directory: URL = defaultDirectory) {
        try? FileManager.default.removeItem(at: directory)
    }
}
