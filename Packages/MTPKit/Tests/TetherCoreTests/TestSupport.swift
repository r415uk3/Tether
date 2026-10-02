import Foundation
import Testing
@testable import TetherCore

func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("TetherCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
func eventually(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("condition not met within \(timeout)")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// The module's compiled Russian strings. Fails the calling test with a clear message (instead of crashing the run)
/// when the string catalog was not compiled, e.g. `swift test` with Xcode older than 27.
func russianBundle() throws -> Bundle {
    let url = try #require(Bundle.module.url(forResource: "ru", withExtension: "lproj"), Comment(rawValue: "ru.lproj not compiled; run tests via xcodebuild (older command-line SwiftPM does not compile string catalogs)"))
    return try #require(Bundle(url: url), "ru.lproj is not a loadable bundle")
}
