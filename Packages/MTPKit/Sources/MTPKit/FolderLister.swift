import Foundation

/// How a folder's entries are read from the phone, with the device calls injected.
///
/// GetObjectInfo (`slow`) costs ~33 ms per photo on Android because the phone opens each file for its EXIF thumbnail
/// size. GetObjectPropList skips that: for the whole folder in one request (`bulk`, ~1.7 ms per object) or per
/// object (`single`, ~8 ms). Bulk sends no progress while it runs, so it is only used up to `bulkLimit` objects,
/// keeping it well inside the app's 15 s idle timeout; bigger folders go per object and report progress as they go.
public enum FolderLister {
    public static let bulkLimit = 3000
    /// After this many `single` refusals in one listing, the phone is assumed not to support it.
    static let singleFailureLimit = 3

    /// - Parameters:
    ///   - bulk: one entry (or nil) per handle, in order; nil overall if the phone refused the request.
    ///   - single: one object via GetObjectPropList, nil if refused or incomplete.
    ///   - slow: one object via GetObjectInfo, nil if it is gone.
    ///   - progress: called after each entry read (and once before a bulk request); return false to cancel.
    ///     Objects that could not be read report nothing, so a phone failing every request still looks stalled.
    public static func list(handles: [UInt32], folderID: UInt32, bulkAllowed: Bool,
                            bulk: ([UInt32]) -> [FileEntry?]?,
                            single: (UInt32) -> FileEntry?,
                            slow: (UInt32) -> FileEntry?,
                            progress: ProgressHandler) throws -> [FileEntry] {
        let total = UInt64(handles.count)
        var known = [FileEntry?](repeating: nil, count: handles.count)
        if bulkAllowed, folderID != FileEntry.rootID, !handles.isEmpty, handles.count <= bulkLimit {
            guard progress(0, total) else { throw MTPError.cancelled }
            if let reply = bulk(handles), reply.count == handles.count { known = reply }
        }

        var entries: [FileEntry] = []
        entries.reserveCapacity(handles.count)
        var singleFailures = 0
        for (index, handle) in handles.enumerated() {
            var entry = known[index]
            if entry == nil, singleFailures < singleFailureLimit {
                entry = single(handle)
                if entry == nil { singleFailures += 1 }
            }
            if entry == nil { entry = slow(handle) }
            guard let entry else { continue } // deleted since the handles were listed
            entries.append(entry)
            guard progress(UInt64(index + 1), total) else { throw MTPError.cancelled }
        }
        return entries
    }
}

/// Remembers phone models whose bulk GetObjectPropList never finished (the helper was killed while it ran, e.g. by
/// the listing timeout), so the next listing doesn't hang the same way. Lives in the helper's defaults.
public final class BulkListingGuard: @unchecked Sendable {
    private static let pendingKey = "BulkListingPending"
    private static let disabledKey = "BulkListingDisabledModels"
    private let model: String
    private let defaults: UserDefaults

    public init(model: String, defaults: UserDefaults = .standard) {
        self.model = model
        self.defaults = defaults
        if defaults.string(forKey: Self.pendingKey) == model {
            var disabled = defaults.stringArray(forKey: Self.disabledKey) ?? []
            if !disabled.contains(model) { disabled.append(model) }
            defaults.set(disabled, forKey: Self.disabledKey)
            defaults.removeObject(forKey: Self.pendingKey)
            DiagnosticLog.shared.record("Bulk listing disabled for this model: a previous request never finished",
                                        category: "device")
        }
    }

    public var isAllowed: Bool {
        !(defaults.stringArray(forKey: Self.disabledKey) ?? []).contains(model)
    }

    public func begin() { defaults.set(model, forKey: Self.pendingKey) }
    public func end() { defaults.removeObject(forKey: Self.pendingKey) }
}
