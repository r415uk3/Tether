import Foundation
import Testing
@testable import MTPKit

@Test func onceContinuationIgnoresSecondResume() async throws {
    let value: Int = try await withCheckedThrowingContinuation { continuation in
        let once = OnceContinuation(continuation)
        once.resume(returning: 1)
        once.resume(returning: 2)
        once.resume(throwing: MTPError.timeout)
    }
    #expect(value == 1)
}

@Test func withTimeoutReturnsFastResult() async throws {
    let called = LockedFlag()
    let value = try await withTimeout(.seconds(5), onTimeout: { called.set() }) { 42 }
    #expect(value == 42)
    #expect(!called.isSet)
}

@Test func withTimeoutThrowsTimeoutAndRunsHandler() async {
    let called = LockedFlag()
    await #expect(throws: MTPError.timeout) {
        try await withTimeout(.milliseconds(50), onTimeout: { called.set() }) {
            try await Task.sleep(for: .seconds(10))
            return 1
        }
    }
    #expect(called.isSet)
}

@Test func withTimeoutPassesThroughOperationErrors() async {
    await #expect(throws: MTPError.notFound) {
        try await withTimeout(.seconds(5), onTimeout: {}) { () async throws -> Int in throw MTPError.notFound }
    }
}

@Test func withIdleTimeoutLetsAnOperationThatKeepsReportingActivityFinish() async throws {
    let activity = ActivityMonitor()
    let called = LockedFlag()
    // 1 s idle limit vs ~20 ms between touches: generous, so a busy CI runner's late wakeups can't trip it,
    // while the whole operation (~400 ms) still outlasts what a plain 100 ms timeout would allow.
    let value = try await withIdleTimeout(.seconds(1), activity: activity, onTimeout: { called.set() }) {
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(20))
            activity.touch()
        }
        return 42
    }
    #expect(value == 42)
    #expect(!called.isSet)
}

@Test func withIdleTimeoutTimesOutWhenActivityStops() async {
    let activity = ActivityMonitor()
    let called = LockedFlag()
    await #expect(throws: MTPError.timeout) {
        try await withIdleTimeout(.milliseconds(100), activity: activity, onTimeout: { called.set() }) {
            for _ in 0..<3 {
                try await Task.sleep(for: .milliseconds(30))
                activity.touch()
            }
            try await Task.sleep(for: .seconds(10))
            return 1
        }
    }
    #expect(called.isSet)
}
