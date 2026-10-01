import Foundation
import MTPKit

/// What VoiceOver reads for files, storages and transfers. Names are passed as arguments, never as format strings.
public enum AccessibilityText {
    public static func file(_ entry: FileEntry) -> String {
        if entry.isFolder {
            return String(localized: "\(entry.name), folder", bundle: .module)
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file)
        return String(localized: "\(entry.name), \(size)", bundle: .module)
    }

    public static func storage(_ storage: StorageInfo) -> String {
        guard storage.capacity > 0 else { return storage.name }
        let free = ByteCountFormatter.string(fromByteCount: Int64(clamping: storage.freeSpace), countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: Int64(clamping: storage.capacity), countStyle: .file)
        return String(localized: "\(storage.name), \(free) available of \(total)", bundle: .module)
    }

    public static func transfer(_ job: TransferQueue.Job) -> String {
        switch job.state {
        case .queued: String(localized: "\(job.name), waiting", bundle: .module)
        case .running:
            String(localized: "\(job.name), \(job.fraction.formatted(.percent.precision(.fractionLength(0))))", bundle: .module)
        case .finished: String(localized: "\(job.name), done", bundle: .module)
        case .cancelled: String(localized: "\(job.name), cancelled", bundle: .module)
        case .failed(let error): String(localized: "\(job.name), failed: \(error.localizedDescription)", bundle: .module)
        }
    }
}
