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

    public static let defaultMemoryLimit = 1500
    public static let defaultDiskLimit: UInt64 = 256 * 1024 * 1024
    @ObservationIgnored private let memoryLimit: Int
    /// Insertion order of `memory`'s keys, oldest first (FIFO eviction).
    @ObservationIgnored private var memoryOrder: [ItemKey] = []

    private static let missingRetryInterval: TimeInterval = 10 * 60
    private static let failureRetryInterval: TimeInterval = 15

    public init(service: any MTPService, directory: URL? = ThumbnailStore.defaultDirectory,
                memoryLimit: Int = ThumbnailStore.defaultMemoryLimit,
                now: @escaping @MainActor () -> Date = Date.init) {
        self.service = service
        self.directory = directory
        self.memoryLimit = max(1, memoryLimit)
        self.now = now
        if let directory {
            Task.detached(priority: .background) {
                await ThumbnailStore.pruneDirectory(directory, toAtMost: ThumbnailStore.defaultDiskLimit)
            }
        }
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
        if memory.updateValue(data, forKey: key) == nil { memoryOrder.append(key) }
        if memory.count > memoryLimit {
            let target = max(1, memoryLimit * 9 / 10)
            let excess = memory.count - target
            for old in memoryOrder.prefix(excess) { memory[old] = nil }
            memoryOrder.removeFirst(min(excess, memoryOrder.count))
        }
        version += 1
    }

    /// Deletes the least recently written files until the directory holds at most `maxBytes`.
    public nonisolated static func pruneDirectory(_ directory: URL, toAtMost maxBytes: UInt64) async {
        await Task.detached {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
            guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
            var files: [(url: URL, size: UInt64, date: Date)] = []
            for url in urls {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                files.append((url, UInt64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast))
            }
            var total = files.reduce(UInt64(0)) { $0 + $1.size }
            for file in files.sorted(by: { $0.date < $1.date }) where total > maxBytes {
                if (try? fm.removeItem(at: file.url)) != nil { total -= min(file.size, total) }
            }
        }.value
    }
}
