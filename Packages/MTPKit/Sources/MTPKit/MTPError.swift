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
            String(localized: "The phone was disconnected.")
        case .deviceLocked:
            String(localized: "Unlock your phone and choose “File transfer” in the USB notification.")
        case .deviceBusy:
            String(localized: "The phone is busy. Try again in a moment.")
        case .claimedByOtherProcess:
            String(localized: "Another app is using the phone. Quit Image Capture or Photos and try again.")
        case .storageFull(let needed, let available):
            String(localized: "Not enough space on the phone. Needs \(Self.bytes(needed)), but only \(Self.bytes(available)) is available.")
        case .nameConflict(let name):
            String(localized: "An item named “\(name)” already exists in this folder.")
        case .notFound:
            String(localized: "The item no longer exists on the phone.")
        case .timeout:
            String(localized: "The phone stopped responding.")
        case .cancelled:
            String(localized: "The transfer was cancelled.")
        case .serviceInterrupted:
            String(localized: "The connection to the phone was interrupted.")
        case .phoneReconnected:
            String(localized: "The phone was reconnected. Open the folder again and retry.")
        case .underlying(_, let message):
            message
        }
    }

    private static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }
}
