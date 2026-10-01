import Foundation
import Testing
@testable import TetherCore

private let repo = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() // Packages/MTPKit
    .deletingLastPathComponent().deletingLastPathComponent()                             // repo root

/// Every String Catalog that ships.
private let catalogs = [
    "Tether/Localizable.xcstrings",
    "Packages/MTPKit/Sources/MTPKit/Resources/Localizable.xcstrings",
    "Packages/MTPKit/Sources/TetherCore/Resources/Localizable.xcstrings",
]

private func load(_ path: String) throws -> [String: [String: Any]] {
    let data = try Data(contentsOf: repo.appending(path: path))
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    return json["strings"] as! [String: [String: Any]]
}

/// True if `localization` (one language's entry) is fully translated, including every plural/device variation.
private func isTranslated(_ localization: [String: Any]?) -> Bool {
    guard let localization else { return false }
    if let unit = localization["stringUnit"] as? [String: Any] { return unit["state"] as? String == "translated" }
    if let variations = localization["variations"] as? [String: [String: [String: Any]]] {
        return !variations.isEmpty && variations.values.allSatisfy { $0.values.allSatisfy(isTranslated) }
    }
    return false
}

@Suite struct LocalizationCatalogTests {
    @Test(arguments: catalogs) func everyKeyHasRussian(_ path: String) throws {
        let strings = try load(path)
        #expect(!strings.isEmpty, "\(path) is empty — run scripts/sync-strings.sh")
        let missing = strings.filter { key, entry in
            if entry["shouldTranslate"] as? Bool == false { return false }
            let localizations = entry["localizations"] as? [String: [String: Any]]
            return !isTranslated(localizations?["ru"])
        }.keys.sorted()
        #expect(missing.isEmpty, "\(path): no Russian for \(missing)")
        let stale = strings.filter { ($0.value["extractionState"] as? String) == "stale" }.keys.sorted()
        #expect(stale.isEmpty, "\(path): stale keys \(stale) — delete them")
    }

    @Test(arguments: catalogs) func russianPluralsHaveAllForms(_ path: String) throws {
        for (key, entry) in try load(path) {
            let ru = (entry["localizations"] as? [String: [String: Any]])?["ru"]
            guard let plural = (ru?["variations"] as? [String: [String: Any]])?["plural"] else { continue }
            #expect(Set(plural.keys).isSuperset(of: ["one", "few", "many", "other"]), "\(path): \(key) needs one/few/many/other")
        }
    }

    @Test func everyTetherCoreStringUsesTheModuleBundle() throws {
        let sources = repo.appending(path: "Packages/MTPKit/Sources/TetherCore")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        var offenders: [String] = []
        for url in files {
            for (i, line) in try String(contentsOf: url, encoding: .utf8).split(separator: "\n").enumerated()
            where line.contains("String(localized:") && !line.contains("bundle: .module") {
                offenders.append("\(url.lastPathComponent):\(i + 1)")
            }
        }
        #expect(offenders.isEmpty, "Missing bundle: .module: \(offenders)")
    }

    @Test func conflictChoicesAreRussian() {
        let ru = Bundle(url: Bundle.module.url(forResource: "ru", withExtension: "lproj")!)!
        #expect(ru.localizedString(forKey: "Keep Both", value: "?", table: nil) == "Оставить оба")
    }
}
