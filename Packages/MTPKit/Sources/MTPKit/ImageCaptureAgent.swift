import Darwin
import Foundation

/// The macOS agents that grab PTP/MTP phones for Image Capture and Photos.
public enum ImageCaptureAgent {
    public static let processNames: [String] = ["ptpcamerad"]

    public static func runningProcessIDs() -> [pid_t] {
        processNames.flatMap { processIDs(named: $0) }
    }

    /// PIDs of this user's processes with exactly this name (libproc).
    public static func processIDs(named name: String) -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).filter { pid in
            guard pid > 0 else { return false }
            var buffer = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self) == name
        }
    }

    /// Asks every running agent to quit (SIGTERM). Returns true if at least one was signalled.
    @discardableResult
    public static func terminate() -> Bool {
        var signalled = false
        for pid in runningProcessIDs() where kill(pid, SIGTERM) == 0 { signalled = true }
        return signalled
    }
}
