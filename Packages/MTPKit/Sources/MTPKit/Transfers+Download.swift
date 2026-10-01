import Foundation

/// Device-agnostic transfer algorithms. Run them on a DeviceWorker thread.
public enum Transfers {}

extension Transfers {
    /// Downloads a file or folder into `directory` and returns the final URL.
    /// Writes to `<name>.partial` first, so failures never leave a broken item behind.
    public static func download(_ entry: FileEntry, from device: any MTPDevice, into directory: URL,
                                progress: ProgressHandler) throws -> URL {
        try verify(entry, on: device)
        let fm = FileManager.default
        let final = uniqueURL(for: entry.name, in: directory)
        let partial = directory.appendingPathComponent(final.lastPathComponent + ".partial")
        try? fm.removeItem(at: partial)
        do {
            if entry.isFolder {
                try downloadFolder(entry, from: device, to: partial, progress: progress)
            } else {
                try device.download(objectID: entry.objectID, to: partial, progress: progress)
            }
            try fm.moveItem(at: partial, to: final)
            return final
        } catch {
            try? fm.removeItem(at: partial)
            throw MTPError.from(error)
        }
    }

    /// Refuses to act on a handle that no longer names this item (e.g. after Android renumbered objects on
    /// reconnect). One GetObjectInfo, no folder listing.
    static func verify(_ entry: FileEntry, on device: any MTPDevice) throws {
        guard let current = try device.objectInfo(objectID: entry.objectID),
              current.name == entry.name,
              current.isFolder == entry.isFolder,
              current.parentID == entry.parentID,
              current.storageID == entry.storageID,
              entry.isFolder || current.size == entry.size else {
            throw MTPError.notFound
        }
    }

    /// Makes a phone-supplied name safe as a single macOS path component.
    public static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\0", with: "")
        return (cleaned.isEmpty || cleaned == "." || cleaned == "..") ? "_" : cleaned
    }

    /// "a.txt" → "a 2.txt" → "a 3.txt" … until `isTaken` returns false.
    public static func uniqueName(for name: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ext.isEmpty ? name : ns.deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !isTaken(candidate) { return candidate }
            n += 1
        }
    }

    /// A URL in `directory` that collides with neither existing items nor in-progress `.partial` items.
    public static func uniqueURL(for name: String, in directory: URL) -> URL {
        let fm = FileManager.default
        let unique = uniqueName(for: safeName(name)) { candidate in
            fm.fileExists(atPath: directory.appendingPathComponent(candidate).path)
                || fm.fileExists(atPath: directory.appendingPathComponent(candidate + ".partial").path)
        }
        return directory.appendingPathComponent(unique)
    }

    private struct RemoteItem {
        let components: [String]
        let entry: FileEntry
    }

    private static func downloadFolder(_ folder: FileEntry, from device: any MTPDevice, to root: URL,
                                       progress: ProgressHandler) throws {
        var items: [RemoteItem] = []
        func walk(_ folderID: UInt32, _ prefix: [String]) throws {
            // Lowercased names already used in this folder (APFS is usually case-insensitive).
            var used = Set<String>()
            let children = try device.listFolder(storageID: folder.storageID, folderID: folderID)
            // Keep-alive: the total is unknown during the walk; lets callers see activity and cancel.
            guard progress(0, 0) else { throw MTPError.cancelled }
            for child in children {
                let name = uniqueName(for: safeName(child.name)) { used.contains($0.lowercased()) }
                used.insert(name.lowercased())
                let components = prefix + [name]
                items.append(RemoteItem(components: components, entry: child))
                if child.isFolder { try walk(child.objectID, components) }
            }
        }
        try walk(folder.objectID, [])

        let fm = FileManager.default
        let total = items.reduce(UInt64(0)) { $0 + ($1.entry.isFolder ? 0 : $1.entry.size) }
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        var received: UInt64 = 0
        for item in items {
            let destination = item.components.reduce(root) { $0.appendingPathComponent($1) }
            if item.entry.isFolder {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            } else {
                let base = received
                try device.download(objectID: item.entry.objectID, to: destination) { done, _ in
                    progress(base + done, total)
                }
                received += item.entry.size
            }
        }
    }
}
