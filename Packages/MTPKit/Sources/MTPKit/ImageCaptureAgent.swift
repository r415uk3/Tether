import Darwin
import Foundation

/// The macOS agents that grab PTP/MTP phones for Image Capture and Photos.
public enum ImageCaptureAgent {
    public static let processNames: [String] = ["ptpcamerad"]
    /// Expected executable path for each name; a process must match name, path and owner to be touched.
    static let executablePaths: [String: String] = ["ptpcamerad": "/usr/libexec/ptpcamerad"]

    public static func runningProcessIDs() -> [pid_t] {
        processNames.flatMap { processIDs(named: $0) }
    }

    /// PIDs of processes owned by the current user whose name and executable path both match `name` (libproc).
    public static func processIDs(named name: String) -> [pid_t] {
        guard executablePaths[name] != nil else { return [] }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).filter { matches($0, name: name) }
    }

    private static func matches(_ pid: pid_t, name: String) -> Bool {
        guard pid > 0, let expectedPath = executablePaths[name] else { return false }
        var nameBuffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0,
              String(decoding: nameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == name
        else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid() else { return false }
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { return false }
        return String(decoding: pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == expectedPath
    }

    /// Asks every running agent to quit (SIGTERM). Returns true if at least one was signalled.
    @discardableResult
    public static func terminate() -> Bool {
        var signalled = false
        for name in processNames {
            for pid in processIDs(named: name) where matches(pid, name: name) && kill(pid, SIGTERM) == 0 {
                signalled = true // re-checked just before kill to narrow PID reuse
            }
        }
        return signalled
    }
}
