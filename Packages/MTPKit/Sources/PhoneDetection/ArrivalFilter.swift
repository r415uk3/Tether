import Foundation

/// Decides whether a USB arrival should open Tether, ignoring wakes, quick reconnects and duplicate notifications.
public struct ArrivalFilter: Sendable {
    public static let wakeGrace: TimeInterval = 10       // spec: ~10 s after wake
    public static let reconnectGrace: TimeInterval = 1   // connection glitches come back in ~0.2 s; a hand replug takes 1.5 s+

    private var present: [UInt64: (key: String, isFileTransfer: Bool)] = [:]
    private var fileTransferLeft: [String: Date] = [:]
    private var lastWake: Date?

    public init() {}

    /// Devices present when the watcher starts; never trigger, but their removal is remembered.
    public mutating func noteExisting(entryID: UInt64, key: String, isFileTransfer: Bool) {
        present[entryID] = (key, isFileTransfer)
    }

    /// Returns true if Tether should open for this arrival.
    public mutating func noteArrival(entryID: UInt64, key: String, isFileTransfer: Bool, at now: Date) -> Bool {
        pruneLeft(now)
        guard present[entryID] == nil else { return false }
        present[entryID] = (key, isFileTransfer)
        guard isFileTransfer else { return false }
        if let lastWake, now.timeIntervalSince(lastWake) < Self.wakeGrace { return false }
        if let left = fileTransferLeft[key], now.timeIntervalSince(left) < Self.reconnectGrace { return false }
        return true
    }

    public mutating func noteRemoval(entryID: UInt64, at now: Date) {
        pruneLeft(now)
        guard let device = present.removeValue(forKey: entryID) else { return }
        if device.isFileTransfer { fileTransferLeft[device.key] = now }
    }

    public mutating func noteWake(at now: Date) {
        lastWake = now
    }

    private mutating func pruneLeft(_ now: Date) {
        fileTransferLeft = fileTransferLeft.filter { now.timeIntervalSince($0.value) < Self.reconnectGrace }
    }
}
