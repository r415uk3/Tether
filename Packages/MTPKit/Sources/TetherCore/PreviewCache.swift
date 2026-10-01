import Foundation
import MTPKit

/// Downloads phone files for Quick Look into a private cache, one directory per item version.
@MainActor
public final class PreviewCache {
    private let service: any MTPService
    private let directory: URL
    private var ready: [ItemKey: URL] = [:]
    private var inFlight: [ItemKey: Task<URL, Error>] = [:]

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
        if let task = inFlight[key] { return try await task.value }

        let folder = directory.appendingPathComponent(key.fileName, isDirectory: true)
        let service = self.service
        let task = Task { () throws -> URL in
            try? FileManager.default.removeItem(at: folder) // a leftover from an interrupted download
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return try await service.download(jobID: UUID(), entry: entry, deviceID: deviceID, into: folder)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let url = try await task.value
        ready[key] = url
        return url
    }

    public func clear() {
        ready.removeAll()
        Self.clear(directory: directory)
    }

    /// Removes the cache directory; safe from any thread (used on quit).
    public nonisolated static func clear(directory: URL = defaultDirectory) {
        try? FileManager.default.removeItem(at: directory)
    }
}
