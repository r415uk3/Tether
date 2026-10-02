import Foundation

/// Owns one device and runs every operation on a dedicated thread, highest priority first.
/// libmtp calls block, and a phone serves one request at a time, so a running job is never preempted.
public final class DeviceWorker: @unchecked Sendable {
    public enum Priority: Int, Sendable, CaseIterable {
        case interactive = 0, transfer = 1, background = 2
    }

    private struct Job {
        let run: (any MTPDevice) -> Void
        let fail: (MTPError) -> Void
        /// Runs once the job is over for good: after `run` returns on the worker thread, or when the job is
        /// dropped without ever running. Never when shutdown fails the running job, whose body is still going.
        let end: () -> Void
    }

    private let device: any MTPDevice
    private let condition = NSCondition()
    private var queues: [[Job]] = Array(repeating: [], count: Priority.allCases.count)
    private var current: Job?
    private var stopReason: MTPError?

    public init(device: any MTPDevice, name: String) {
        self.device = device
        let thread = Thread { [self] in runLoop() }
        thread.name = "DeviceWorker \(name)"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// True once `shutdown` was called. A running job's body keeps going after shutdown fails its caller, so long
    /// operations poll this (through their progress handler) and abort.
    public var isStopping: Bool {
        condition.withLock { stopReason != nil }
    }

    /// `onEnd` runs when the operation has really finished on the worker thread (or was dropped unrun), which can be
    /// after this call already threw because of `shutdown`.
    public func perform<T: Sendable>(_ priority: Priority,
                                     onEnd: (@Sendable () -> Void)? = nil,
                                     _ body: @escaping @Sendable (any MTPDevice) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = OnceContinuation(continuation)
            let job = Job(
                run: { device in
                    do { once.resume(returning: try body(device)) } catch { once.resume(throwing: MTPError.from(error)) }
                },
                fail: { once.resume(throwing: $0) },
                end: { onEnd?() }
            )
            condition.lock()
            if let stopReason {
                condition.unlock()
                job.fail(stopReason)
                job.end()
                return
            }
            queues[priority.rawValue].append(job)
            condition.signal()
            condition.unlock()
        }
    }

    public func shutdown(reason: MTPError) {
        condition.lock()
        guard stopReason == nil else { condition.unlock(); return }
        stopReason = reason
        let running = current
        let dropped = queues.flatMap { $0 }
        queues = Array(repeating: [], count: Priority.allCases.count)
        condition.signal()
        condition.unlock()
        // The running job's body is still on the worker thread; its `end` runs when the body returns.
        running?.fail(reason)
        dropped.forEach { $0.fail(reason); $0.end() }
    }

    private func runLoop() {
        while true {
            condition.lock()
            while stopReason == nil && queues.allSatisfy(\.isEmpty) { condition.wait() }
            if stopReason != nil {
                current = nil
                condition.unlock()
                break
            }
            let index = queues.firstIndex { !$0.isEmpty }!
            let job = queues[index].removeFirst()
            current = job
            condition.unlock()

            job.run(device)
            job.end()

            condition.lock()
            current = nil
            condition.unlock()
        }
        device.close()
    }
}
