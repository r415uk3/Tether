import Foundation

/// Carries a non-Sendable value across isolation when the caller guarantees safe use
/// (AppKit callbacks, XPC proxies).
public struct Unchecked<Value>: @unchecked Sendable {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}

/// A continuation that several racing paths may try to resume; only the first wins.
public final class OnceContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    public init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    public func resume(with result: Result<T, Error>) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    public func resume(returning value: T) { resume(with: .success(value)) }
    public func resume(throwing error: Error) { resume(with: .failure(error)) }
}

public final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public func set() { lock.withLock { value = true } }
    public var isSet: Bool { lock.withLock { value } }
}

/// Runs `operation`; if it takes longer than `duration`, calls `onTimeout` and throws `.timeout`.
/// `onTimeout` must make a stuck `operation` finish (e.g. restart the service that is hung),
/// because the task group waits for every child before returning.
public func withTimeout<T: Sendable>(
    _ duration: Duration,
    onTimeout: @escaping @Sendable () async -> Void,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let timedOut = LockedFlag()
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            timedOut.set()
            await onTimeout()
            throw MTPError.timeout
        }
        defer { group.cancelAll() }
        do {
            guard let result = try await group.next() else { throw MTPError.timeout }
            return result
        } catch {
            throw timedOut.isSet ? MTPError.timeout : error
        }
    }
}

/// Runs a blocking call (libmtp `open`, agent termination) off Swift's cooperative pool.
/// The pool has about one thread per core, so blocking inside `Task.detached` can starve every task, including the
/// one that would unblock the call. GCD's global queue adds threads for blocked work, so blocking here is safe.
func runBlocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
    }
}
