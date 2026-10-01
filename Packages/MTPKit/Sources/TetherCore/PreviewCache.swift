import Foundation
import MTPKit

/// Downloads phone files for Quick Look into a private cache, one directory per item version.
@MainActor
public final class PreviewCache {
    private let service: any MTPService
    private let directory: URL
    private var ready: [ItemKey: URL] = [:]
    private struct InFlight {
        let task: Task<URL, Error>
        let jobID: UUID
        let token: UUID
        let deviceID: DeviceID
    }
    private var inFlight: [ItemKey: InFlight] = [:]

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
        defer { if inFlight[key]?.token == token { inFlight[key] = nil } } // clear() may have replaced it
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
        let service = self.service
        for running in inFlight.values {
            let jobID = running.jobID
            Task { await service.cancel(jobID: jobID) }
        }
        inFlight.removeAll()
        Self.clear(directory: directory)
    }

    /// Removes the cache directory; safe from any thread (used on quit).
    public nonisolated static func clear(directory: URL = defaultDirectory) {
        try? FileManager.default.removeItem(at: directory)
    }
}
