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

    public func perform<T: Sendable>(_ priority: Priority,
                                     _ body: @escaping @Sendable (any MTPDevice) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = OnceContinuation(continuation)
            let job = Job(
                run: { device in
                    do { once.resume(returning: try body(device)) } catch { once.resume(throwing: MTPError.from(error)) }
                },
                fail: { once.resume(throwing: $0) }
            )
            condition.lock()
            if let stopReason {
                condition.unlock()
                job.fail(stopReason)
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
        let abandoned = (current.map { [$0] } ?? []) + queues.flatMap { $0 }
        queues = Array(repeating: [], count: Priority.allCases.count)
        condition.signal()
        condition.unlock()
        abandoned.forEach { $0.fail(reason) }
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

            condition.lock()
            current = nil
            condition.unlock()
        }
        device.close()
    }
}
