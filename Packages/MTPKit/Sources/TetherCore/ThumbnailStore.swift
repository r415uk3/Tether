import Foundation
import Observation
import MTPKit

@MainActor
@Observable
public final class ThumbnailStore {
    /// Bumped whenever a thumbnail arrives; views observe it to refresh visible items.
    public private(set) var version = 0

    @ObservationIgnored private var memory: [ItemKey: Data] = [:]
    @ObservationIgnored private var missing: Set<ItemKey> = []
    @ObservationIgnored private var inFlight: Set<ItemKey> = []
    @ObservationIgnored private let service: any MTPService
    @ObservationIgnored private let directory: URL?

    public init(service: any MTPService, directory: URL? = ThumbnailStore.defaultDirectory) {
        self.service = service
        self.directory = directory
    }

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
        guard memory[key] == nil, !missing.contains(key), !inFlight.contains(key) else { return }
        inFlight.insert(key)
        let file = directory?.appendingPathComponent(key.fileName)
        let service = self.service
        Task {
            defer { inFlight.remove(key) }
            if let file, let data = try? Data(contentsOf: file) {
                store(data, for: key)
                return
            }
            do {
                guard let data = try await service.thumbnail(objectID: entry.objectID, in: folder) else {
                    missing.insert(key) // the phone has none; don't ask again
                    return
                }
                if let file {
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                             withIntermediateDirectories: true)
                    try? data.write(to: file, options: .atomic)
                }
                store(data, for: key)
            } catch {
                // Busy / disconnected: leave it unmarked so a later request retries.
            }
        }
    }

    private func store(_ data: Data, for key: ItemKey) {
        memory[key] = data
        version += 1
    }
}
