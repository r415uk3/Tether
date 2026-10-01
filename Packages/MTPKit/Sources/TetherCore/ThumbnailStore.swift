import Foundation
import Observation
import MTPKit

@MainActor
@Observable
public final class ThumbnailStore {
    /// Bumped whenever a thumbnail arrives; views observe it to refresh visible items.
    public private(set) var version = 0

    @ObservationIgnored private var memory: [ItemKey: Data] = [:]
    /// Keys not to ask the phone about again until the date passes.
    @ObservationIgnored private var retryAfter: [ItemKey: Date] = [:]
    @ObservationIgnored private var inFlight: Set<ItemKey> = []
    @ObservationIgnored private let service: any MTPService
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private let now: @MainActor () -> Date

    private static let missingRetryInterval: TimeInterval = 10 * 60
    private static let failureRetryInterval: TimeInterval = 15

    public init(service: any MTPService, directory: URL? = ThumbnailStore.defaultDirectory,
                now: @escaping @MainActor () -> Date = Date.init) {
        self.service = service
        self.directory = directory
        self.now = now
    }

    /// Number of thumbnails currently loading (test hook).
    var pendingCount: Int { inFlight.count }

    public static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("dev.tether.Tether/thumbnails", isDirectory: true)
    }

    private static let extensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "dng",
        "mp4", "mov", "m4v", "3gp", "mkv", "webm",
    ]

    public static func wantsThumbnail(_ entry: FileEntry) -> Bool {
        !entry.isFolder && extensions.contains((entry.name as NSString).pathExtension.lowercased())
    }

    public func cached(_ entry: FileEntry, deviceID: DeviceID) -> Data? {
        memory[ItemKey(entry: entry, deviceID: deviceID)]
    }

    /// Starts loading the thumbnail if it isn't cached, missing, or already loading. Safe to call often.
    public func request(_ entry: FileEntry, in folder: FolderRef) {
        guard Self.wantsThumbnail(entry) else { return }
        let key = ItemKey(entry: entry, deviceID: folder.deviceID)
        guard memory[key] == nil, !inFlight.contains(key) else { return }
        if let date = retryAfter[key], now() < date { return }
        inFlight.insert(key)
        let file = directory?.appendingPathComponent(key.fileName)
        let service = self.service
        Task {
            defer { inFlight.remove(key) }
            if let file, let data = await Self.readCached(file) {
                store(data, for: key)
                return
            }
            do {
                guard let data = try await service.thumbnail(objectID: entry.objectID, in: folder) else {
                    retryAfter[key] = now().addingTimeInterval(Self.missingRetryInterval)
                    return
                }
                retryAfter[key] = nil
                if let file { await Self.writeCached(data, to: file) }
                store(data, for: key)
            } catch {
                // Busy / disconnected: back off briefly, then a later request retries.
                retryAfter[key] = now().addingTimeInterval(Self.failureRetryInterval)
            }
        }
    }

    /// Reads a cache file off the main actor; an empty or unreadable file is removed and treated as a miss.
    private nonisolated static func readCached(_ file: URL) async -> Data? {
        await Task.detached {
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            if let data = try? Data(contentsOf: file), !data.isEmpty { return data }
            try? FileManager.default.removeItem(at: file)
            return nil
        }.value
    }

    private nonisolated static func writeCached(_ data: Data, to file: URL) async {
        await Task.detached {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }.value
    }

    private func store(_ data: Data, for key: ItemKey) {
        memory[key] = data
        version += 1
    }
}
