import Foundation

extension Transfers {
    /// Uploads a file or folder into `parentID`. Checks space and name clashes before sending anything;
    /// `conflict` decides what a clash means (see `ConflictResolution`).
    public static func upload(_ source: URL, to device: any MTPDevice, storageID: UInt32, parentID: UInt32,
                              conflict: ConflictResolution = .fail, progress: ProgressHandler) throws -> FileEntry {
        let scanned = try LocalItem.scan(source)
        let total = scanned.reduce(UInt64(0)) { $0 + $1.size }

        guard let storage = try device.storages().first(where: { $0.id == storageID }) else { throw MTPError.notFound }
        guard storage.freeSpace >= total else {
            throw MTPError.storageFull(needed: total, available: storage.freeSpace)
        }
        let name = source.lastPathComponent
        let existing = try device.listFolder(storageID: storageID, folderID: parentID)
        let clashing = existing.filter { $0.name == name }
        let uploadName = try destinationName(for: name, clashing: clashing, existing: existing, conflict: conflict)
        let items = uploadName == name ? scanned : scanned.map { $0.renamingRoot(to: uploadName) }

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
                    guard progress(sent, total) else { throw MTPError.cancelled }
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
                removeIncomplete(named: uploadName, in: parentID, storageID: storageID,
                                 keeping: Set(existing.map(\.objectID)), on: device)
            }
            throw MTPError.from(error)
        }

        if conflict == .replace, !clashing.isEmpty {
            return try swapIn(createdRoot!, replacing: clashing, finalName: name, on: device)
        }
        return createdRoot!
    }

    /// The name the new item is uploaded under, given the folder's current contents.
    private static func destinationName(for name: String, clashing: [FileEntry], existing: [FileEntry],
                                        conflict: ConflictResolution) throws -> String {
        guard !clashing.isEmpty else { return name }
        let taken = Set(existing.map(\.name))
        switch conflict {
        case .fail: throw MTPError.nameConflict(name)
        case .keepBoth: return uniqueName(for: name) { taken.contains($0) }
        case .replace: return uniqueName(for: name + ".tether-upload") { taken.contains($0) }
        }
    }

    /// Final step of a Replace: the new item is complete under a temporary name.
    /// Delete the old item(s), then give the new one the original name. If deleting fails the original may be
    /// partly removed, so the new copy is always kept (under its temporary name) and the error says so.
    private static func swapIn(_ uploaded: FileEntry, replacing old: [FileEntry], finalName: String,
                               on device: any MTPDevice) throws -> FileEntry {
        do {
            for entry in old { try device.delete(objectID: entry.objectID) }
        } catch {
            let reason = MTPError.from(error).localizedDescription
            throw MTPError.underlying(code: -5, message: String(
                localized: "The new “\(finalName)” was copied as “\(uploaded.name)”, but the existing item couldn’t be removed. \(reason)"))
        }
        do {
            try device.rename(objectID: uploaded.objectID, to: finalName)
        } catch {
            let reason = MTPError.from(error).localizedDescription
            throw MTPError.underlying(code: -4, message: String(
                localized: "The new “\(finalName)” was copied as “\(uploaded.name)” but couldn’t be renamed. \(reason)"))
        }
        var renamed = uploaded
        renamed.name = finalName
        return renamed
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

    /// The same item uploaded under a different top-level name (Keep Both / Replace's temporary name).
    func renamingRoot(to name: String) -> LocalItem {
        LocalItem(components: [name] + components.dropFirst(), url: url, isDirectory: isDirectory, size: size)
    }

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
