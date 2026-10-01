import Foundation
import os

/// A small in-memory log for Help → Copy Diagnostics, mirrored to the unified log.
/// Never record file names, folder names or device serials here.
public final class DiagnosticLog: @unchecked Sendable {
    public static let shared = DiagnosticLog()

    private let capacity: Int
    private let lock = NSLock()
    private var lines: [String] = []

    public init(capacity: Int = 500) {
        self.capacity = max(1, capacity)
    }

    public func record(_ message: String, category: String = "general") {
        let line = "\(Date().formatted(.iso8601)) [\(category)] \(message)"
        Logger(subsystem: "dev.tether.Tether", category: category).log("\(message, privacy: .public)")
        lock.withLock {
            lines.append(line)
            if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        }
    }

    public func snapshot() -> [String] {
        lock.withLock { lines }
    }
}
