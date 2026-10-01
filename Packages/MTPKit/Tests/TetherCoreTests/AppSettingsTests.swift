import Foundation
import Testing
@testable import TetherCore

@Suite struct AppSettingsTests {
    private func makeDefaults() -> UserDefaults { UserDefaults(suiteName: "AppSettingsTests-\(UUID().uuidString)")! }

    @Test func downloadFolderFallsBackToDownloads() {
        let defaults = makeDefaults()
        #expect(AppSettings.downloadFolder(in: defaults) == AppSettings.defaultDownloadFolder)
        defaults.set("/definitely/not/here", forKey: SettingsKey.downloadFolderPath)
        #expect(AppSettings.downloadFolder(in: defaults) == AppSettings.defaultDownloadFolder)
    }

    @Test func downloadFolderUsesAnExistingDirectory() throws {
        let defaults = makeDefaults()
        let dir = try makeTempDirectory()
        defaults.set(dir.path, forKey: SettingsKey.downloadFolderPath)
        #expect(AppSettings.downloadFolder(in: defaults).standardizedFileURL == dir.standardizedFileURL)
    }

    @Test func conflictDefaultParsesAndFallsBack() {
        let defaults = makeDefaults()
        #expect(AppSettings.conflictDefault(in: defaults) == .ask)
        defaults.set("keepBoth", forKey: SettingsKey.conflictDefault)
        #expect(AppSettings.conflictDefault(in: defaults) == .keepBoth)
        defaults.set("bogus", forKey: SettingsKey.conflictDefault)
        #expect(AppSettings.conflictDefault(in: defaults) == .ask)
        #expect(ConflictDefault.ask.choice == nil)
        #expect(ConflictDefault.skip.choice == .skip)
        for value in ConflictDefault.allCases { #expect(!value.title.isEmpty) }
    }
}
