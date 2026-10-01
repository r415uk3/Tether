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
