import Foundation
import CLibMTP
import MTPKit

/// libmtp-backed phone. Not thread-safe; DeviceWorker confines every call to one thread.
final class LibMTPDevice: MTPDevice, @unchecked Sendable {
    let info: DeviceInfo
    private var handle: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?

    init(handle: UnsafeMutablePointer<LIBMTP_mtpdevice_t>, attached: AttachedDevice) {
        self.handle = handle
        let manufacturer = Self.take(LIBMTP_Get_Manufacturername(handle)) ?? attached.manufacturer
        let model = Self.take(LIBMTP_Get_Modelname(handle)) ?? attached.model
        let serial = Self.take(LIBMTP_Get_Serialnumber(handle))
        info = DeviceInfo(id: serial.map { "serial-\($0)" } ?? attached.id,
                          manufacturer: manufacturer, model: model, state: .ready)
    }

    func storages() throws -> [StorageInfo] {
        let h = try requireHandle()
        // 0 = full storage info; 1 = storage IDs only (partial success); negative = failure.
        guard LIBMTP_Get_Storage(h, 0) >= 0 else { throw lastError(h) } // 0 = LIBMTP_STORAGE_SORTBY_NOTSORTED
        var result: [StorageInfo] = []
        var storage = h.pointee.storage
        while let s = storage {
            result.append(StorageInfo(id: s.pointee.id,
                                      name: s.pointee.StorageDescription.map { String(cString: $0) } ?? "Storage",
                                      capacity: s.pointee.MaxCapacity,
                                      freeSpace: s.pointee.FreeSpaceInBytes))
            storage = s.pointee.next
        }
        return result
    }

    /// Converts a libmtp file record; libmtp reports root children with parent_id 0.
    private static func entry(from f: UnsafeMutablePointer<LIBMTP_file_t>) -> FileEntry {
        FileEntry(
            objectID: f.pointee.item_id,
            parentID: f.pointee.parent_id == 0 ? FileEntry.rootID : f.pointee.parent_id,
            storageID: f.pointee.storage_id,
            name: f.pointee.filename.map { String(cString: $0) } ?? "",
            size: f.pointee.filesize,
            modified: f.pointee.modificationdate == 0 ? nil
                : Date(timeIntervalSince1970: TimeInterval(f.pointee.modificationdate)),
            isFolder: f.pointee.filetype == LIBMTP_FILETYPE_FOLDER)
    }

    func listFolder(storageID: UInt32, folderID: UInt32) throws -> [FileEntry] {
        let h = try requireHandle()
        LIBMTP_Clear_Errorstack(h)
        var entries: [FileEntry] = []
        var file = LIBMTP_Get_Files_And_Folders(h, storageID, folderID)
        while let f = file {
            let next = f.pointee.next
            entries.append(Self.entry(from: f))
            LIBMTP_destroy_file_t(f)
            file = next
        }
        // An empty folder and a failure both return NULL; the error stack tells them apart.
        if entries.isEmpty, LIBMTP_Get_Errorstack(h) != nil { throw lastError(h) }
        return entries
    }

    func objectInfo(objectID: UInt32) throws -> FileEntry? {
        let h = try requireHandle()
        LIBMTP_Clear_Errorstack(h)
        guard let f = LIBMTP_Get_Filemetadata(h, objectID) else {
            // libmtp 1.1.23 returns NULL for a vanished handle and for a dead connection alike, and this call
            // does not populate the errorstack. Probe the connection to tell them apart.
            if LIBMTP_Get_Storage(h, 0) < 0 {
                let error = lastError(h)
                if case .underlying(let code, _) = error, code == -1 { throw MTPError.deviceDisconnected }
                throw error
            }
            return nil
        }
        defer { LIBMTP_destroy_file_t(f) }
        return Self.entry(from: f)
    }

    func download(objectID: UInt32, to fileURL: URL, progress: ProgressHandler) throws {
        let h = try requireHandle()
        let rc = withProgressContext(progress) { context in
            fileURL.withUnsafeFileSystemRepresentation { path in
                LIBMTP_Get_File_To_File(h, objectID, path, { sent, total, data in
                    reportProgress(sent, total, data)
                }, context)
            }
        }
        if rc != 0 { throw lastError(h) }
        // libmtp creates the file as 0740 (owner-executable, unreadable by others); normalise. Non-fatal.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
    }

    func upload(from fileURL: URL, name: String, size: UInt64, storageID: UInt32, parentID: UInt32,
                progress: ProgressHandler) throws -> FileEntry {
        let h = try requireHandle()
        guard let file = LIBMTP_new_file_t() else { throw MTPError.underlying(code: -1, message: "Out of memory") }
        defer { LIBMTP_destroy_file_t(file) } // also frees filename
        file.pointee.filename = strdup(name)
        file.pointee.filesize = size
        file.pointee.filetype = LIBMTP_FILETYPE_UNKNOWN
        file.pointee.parent_id = Self.mtpParent(parentID)
        file.pointee.storage_id = storageID
        let rc = withProgressContext(progress) { context in
            fileURL.withUnsafeFileSystemRepresentation { path in
                LIBMTP_Send_File_From_File(h, path, file, { sent, total, data in
                    reportProgress(sent, total, data)
                }, context)
            }
        }
        if rc != 0 { throw lastError(h) }
        return FileEntry(objectID: file.pointee.item_id, parentID: parentID, storageID: storageID, name: name,
                         size: size, modified: Date(), isFolder: false)
    }

    func createFolder(name: String, storageID: UInt32, parentID: UInt32) throws -> FileEntry {
        let h = try requireHandle()
        let cName = strdup(name)
        defer { free(cName) }
        let id = LIBMTP_Create_Folder(h, cName, Self.mtpParent(parentID), storageID)
        if id == 0 { throw lastError(h) }
        return FileEntry(objectID: id, parentID: parentID, storageID: storageID, name: name, size: 0,
                         modified: Date(), isFolder: true)
    }

    func rename(objectID: UInt32, to newName: String) throws {
        let h = try requireHandle()
        let cName = strdup(newName)
        defer { free(cName) }
        if LIBMTP_Set_Object_Filename(h, objectID, cName) != 0 { throw lastError(h) }
    }

    func delete(objectID: UInt32) throws {
        let h = try requireHandle()
        if LIBMTP_Delete_Object(h, objectID) != 0 { throw lastError(h) }
    }

    func thumbnail(objectID: UInt32) throws -> Data? {
        let h = try requireHandle()
        LIBMTP_Clear_Errorstack(h)
        var data: UnsafeMutablePointer<UInt8>?
        var size: UInt32 = 0
        let rc = LIBMTP_Get_Thumbnail(h, objectID, &data, &size)
        defer { if let data { free(data) } }
        guard rc == 0, let data, size > 0 else {
            if rc != 0 {
                // LIBMTP_Get_Thumbnail returns -1 without populating the errorstack, so lastError cannot tell
                // "no thumbnail" from a dead connection. Probe the connection (as objectInfo does).
                if LIBMTP_Get_Storage(h, 0) < 0 {
                    let error = lastError(h)
                    if case .underlying(let code, _) = error, code == -1 { throw MTPError.deviceDisconnected }
                    throw error
                }
            }
            return nil // no thumbnail for this object
        }
        return Data(bytes: data, count: Int(size))
    }

    func close() {
        if let handle { LIBMTP_Release_Device(handle) }
        handle = nil
    }

    // MARK: Internals

    private func requireHandle() throws -> UnsafeMutablePointer<LIBMTP_mtpdevice_t> {
        guard let handle else { throw MTPError.deviceDisconnected }
        return handle
    }

    /// libmtp uses 0 for "root" when creating objects, but 0xFFFFFFFF when listing.
    private static func mtpParent(_ parentID: UInt32) -> UInt32 {
        parentID == FileEntry.rootID ? 0 : parentID
    }

    private static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { free(pointer) }
        let string = String(cString: pointer)
        return string.isEmpty ? nil : string
    }

    private func lastError(_ h: UnsafeMutablePointer<LIBMTP_mtpdevice_t>) -> MTPError {
        defer { LIBMTP_Clear_Errorstack(h) }
        var last: (number: LIBMTP_error_number_t, text: String)?
        var error = LIBMTP_Get_Errorstack(h)
        while let e = error {
            last = (e.pointee.errornumber, e.pointee.error_text.map { String(cString: $0) } ?? "")
            error = e.pointee.next
        }
        guard let last else { return .underlying(code: -1, message: "Unknown libmtp error") }
        switch last.number {
        case LIBMTP_ERROR_CANCELLED: return .cancelled
        case LIBMTP_ERROR_NO_DEVICE_ATTACHED, LIBMTP_ERROR_USB_LAYER: return .deviceDisconnected
        case LIBMTP_ERROR_STORAGE_FULL: return .storageFull(needed: 0, available: 0)
        default: return .underlying(code: Int(last.number.rawValue), message: last.text)
        }
    }
}

// MARK: Progress bridging to libmtp's C callback

private final class ProgressBox {
    let handler: ProgressHandler
    init(_ handler: @escaping ProgressHandler) { self.handler = handler }
}

private func withProgressContext<R>(_ progress: ProgressHandler, _ body: (UnsafeRawPointer) -> R) -> R {
    withoutActuallyEscaping(progress) { escapable in
        let box = ProgressBox(escapable)
        return withExtendedLifetime(box) {
            body(UnsafeRawPointer(Unmanaged.passUnretained(box).toOpaque()))
        }
    }
}

/// Returns non-zero to make libmtp cancel the transfer.
private func reportProgress(_ sent: UInt64, _ total: UInt64, _ data: UnsafeRawPointer?) -> Int32 {
    guard let data else { return 0 }
    let box = Unmanaged<ProgressBox>.fromOpaque(data).takeUnretainedValue()
    return box.handler(sent, total) ? 0 : 1
}
