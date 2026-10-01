import Foundation

extension Transfers {
    /// Uploads a file or folder into `parentID`. Checks space and name conflicts before sending anything.
    public static func upload(_ source: URL, to device: any MTPDevice, storageID: UInt32, parentID: UInt32,
                              progress: ProgressHandler) throws -> FileEntry {
        let items = try LocalItem.scan(source)
        let total = items.reduce(UInt64(0)) { $0 + $1.size }

        guard let storage = try device.storages().first(where: { $0.id == storageID }) else { throw MTPError.notFound }
        guard storage.freeSpace >= total else {
            throw MTPError.storageFull(needed: total, available: storage.freeSpace)
        }
        let name = source.lastPathComponent
        let existing = try device.listFolder(storageID: storageID, folderID: parentID)
        guard !existing.contains(where: { $0.name == name }) else { throw MTPError.nameConflict(name) }

        var createdRoot: FileEntry?
        var folderIDs: [[String]: UInt32] = [[]: parentID]
        var sent: UInt64 = 0
        do {
            for item in items {
                guard let parent = folderIDs[Array(item.components.dropLast())] else {
                    throw MTPError.underlying(code: -3, message: "Unexpected path while uploading \(name)")
                }
                let itemName = item.components.last!
                let created: FileEntry
                if item.isDirectory {
                    created = try device.createFolder(name: itemName, storageID: storageID, parentID: parent)
                    folderIDs[item.components] = created.objectID
                } else {
                    let base = sent
                    created = try device.upload(from: item.url, name: itemName, size: item.size,
                                                storageID: storageID, parentID: parent) { done, _ in
                        progress(base + done, total)
                    }
                    sent += item.size
                }
                if createdRoot == nil { createdRoot = created }
            }
        } catch {
            if let createdRoot {
                try? device.delete(objectID: createdRoot.objectID)
            } else {
                removeIncomplete(named: name, in: parentID, storageID: storageID,
                                 keeping: Set(existing.map(\.objectID)), on: device)
            }
            throw MTPError.from(error)
        }
        return createdRoot!
    }

    /// Deletes objects named `name` that appeared during a failed upload. Best effort.
    private static func removeIncomplete(named name: String, in parentID: UInt32, storageID: UInt32,
                                         keeping: Set<UInt32>, on device: any MTPDevice) {
        guard let entries = try? device.listFolder(storageID: storageID, folderID: parentID) else { return }
        for entry in entries where entry.name == name && !keeping.contains(entry.objectID) {
            try? device.delete(objectID: entry.objectID)
        }
    }
}

/// A local file or folder to upload; `components` is the path relative to the upload's parent,
/// starting with the source's own name.
struct LocalItem {
    let components: [String]
    let url: URL
    let isDirectory: Bool
    let size: UInt64

    /// Pre-order list (folders before their contents), hidden files skipped.
    static func scan(_ source: URL) throws -> [LocalItem] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
        let rootValues = try source.resourceValues(forKeys: keys)
        let rootIsDirectory = rootValues.isDirectory ?? false
        var items = [LocalItem(components: [source.lastPathComponent], url: source, isDirectory: rootIsDirectory,
                               size: rootIsDirectory ? 0 : UInt64(rootValues.fileSize ?? 0))]
        guard rootIsDirectory else { return items }

        // Resolve symlinks (/var → /private/var) so relative paths are computed consistently.
        let rootDepth = source.resolvingSymlinksInPath().pathComponents.count
        guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: Array(keys),
                                                              options: [.skipsHiddenFiles]) else { return items }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { continue } // links are skipped, never followed
            let isDirectory = values.isDirectory ?? false
            let relative = url.resolvingSymlinksInPath().pathComponents.dropFirst(rootDepth)
            items.append(LocalItem(components: [source.lastPathComponent] + relative, url: url,
                                   isDirectory: isDirectory, size: isDirectory ? 0 : UInt64(values.fileSize ?? 0)))
        }
        return items
    }
}
