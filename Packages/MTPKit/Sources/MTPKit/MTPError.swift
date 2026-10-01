import Foundation

public enum MTPError: Error, Codable, Hashable, Sendable {
    case deviceDisconnected
    case deviceLocked
    case deviceBusy
    case claimedByOtherProcess
    case storageFull(needed: UInt64, available: UInt64)
    case nameConflict(String)
    case notFound
    case timeout
    case cancelled
    case serviceInterrupted
    case phoneReconnected
    case underlying(code: Int, message: String)

    public static let unexpectedResponse = MTPError.underlying(code: -2, message: "Unexpected response from MTPHelper.")

    public static func from(_ error: Error) -> MTPError {
        if let error = error as? MTPError { return error }
        let ns = error as NSError
        return .underlying(code: ns.code, message: ns.localizedDescription)
    }
}

extension MTPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .deviceDisconnected:
            String(localized: "The phone was disconnected.", bundle: .module)
        case .deviceLocked:
            String(localized: "Unlock your phone and choose “File transfer” in the USB notification.", bundle: .module)
        case .deviceBusy:
            String(localized: "The phone is busy. Try again in a moment.", bundle: .module)
        case .claimedByOtherProcess:
            String(localized: "Another app is using the phone. Quit Image Capture or Photos and try again.", bundle: .module)
        case .storageFull(let needed, let available):
            String(localized: "Not enough space on the phone. Needs \(Self.bytes(needed)), but only \(Self.bytes(available)) is available.", bundle: .module)
        case .nameConflict(let name):
            String(localized: "An item named “\(name)” already exists in this folder.", bundle: .module)
        case .notFound:
            String(localized: "The item no longer exists on the phone.", bundle: .module)
        case .timeout:
            String(localized: "The phone stopped responding.", bundle: .module)
        case .cancelled:
            String(localized: "The transfer was cancelled.", bundle: .module)
        case .serviceInterrupted:
            String(localized: "The connection to the phone was interrupted.", bundle: .module)
        case .phoneReconnected:
            String(localized: "The phone was reconnected. Upload the item again from its folder.", bundle: .module)
        case .underlying(-7, _):
            String(localized: "Tether couldn’t open the phone. Unplug it, plug it back in, and choose “File transfer”.", bundle: .module)
        // -4...-6 carry already-localized messages built by Tether itself; other negative codes are helper-internal English text.
        case .underlying(let code, _) where code < 0 && !(-6 ... -4).contains(code):
            String(localized: "Something went wrong while talking to the phone. Try again, or reconnect it.", bundle: .module)
        case .underlying(_, let message):
            message
        }
    }

    /// A description for logs and diagnostics: only the kind and code, never names, paths or free-form messages.
    public var logDescription: String {
        switch self {
        case .deviceDisconnected: "deviceDisconnected"
        case .deviceLocked: "deviceLocked"
        case .deviceBusy: "deviceBusy"
        case .claimedByOtherProcess: "claimedByOtherProcess"
        case .storageFull(let needed, let available): "storageFull(needed: \(needed), available: \(available))"
        case .nameConflict: "nameConflict"
        case .notFound: "notFound"
        case .timeout: "timeout"
        case .cancelled: "cancelled"
        case .serviceInterrupted: "serviceInterrupted"
        case .phoneReconnected: "phoneReconnected"
        case .underlying(let code, _): "underlying(code: \(code))"
        }
    }

    private static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }
}
