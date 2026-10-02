import Foundation
import Testing
@testable import MTPKit

@Suite struct LocalizationTests {
    @Test func everyLocalizedStringUsesTheModuleBundle() throws {
        let offenders = try sourceLines(module: "MTPKit").filter {
            $0.line.contains("String(localized:") && !$0.line.contains("bundle: .module")
        }
        #expect(offenders.isEmpty, "Missing bundle: .module: \(offenders.map(\.location))")
    }

    @Test func errorMessagesHaveRussianTranslations() throws {
        let ru = try russianBundle()
        #expect(ru.localizedString(forKey: "The phone was disconnected.", value: "?", table: nil) == "Телефон отключён.")
        let format = ru.localizedString(forKey: "An item named “%@” already exists in this folder.", value: "?", table: nil)
        #expect(String(format: format, "50% off %@.jpg").contains("50% off %@.jpg"))
        #expect(format != "?" && format != "An item named “%@” already exists in this folder.")
    }

    @Test func helperInternalErrorsGetFriendlyText() {
        #expect(MTPError.underlying(code: -7, message: "raw libmtp text").errorDescription?.contains("raw") == false)
        #expect(MTPError.unexpectedResponse.errorDescription?.contains("MTPHelper") == false)
        #expect(MTPError.underlying(code: 13, message: "Disk full").errorDescription == "Disk full")
    }

    @Test func libmtpCodesGetGenericTextWithoutRawMessage() {
        for raw in [1, 2, 8] {
            let error = MTPError.underlying(code: MTPError.libmtpCode(raw), message: "PTP Layer error 02ff")
            #expect(error.errorDescription?.contains("PTP") == false)
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.logDescription == "underlying(code: \(-100 - raw))")
        }
    }

    @Test(arguments: [-4, -5, -6]) func tetherLocalizedUnderlyingMessagesPassThrough(_ code: Int) {
        #expect(MTPError.underlying(code: code, message: "x").errorDescription == "x")
    }

    @Test(arguments: [-1, -3]) func helperInternalNegativeCodesGetGenericText(_ code: Int) {
        let text = MTPError.underlying(code: code, message: "raw detail").errorDescription
        #expect(text != "raw detail" && text?.contains("raw detail") == false)
        #expect(text?.isEmpty == false)
    }
}

/// Lines of the module's Swift sources, with "File.swift:line" locations.
func sourceLines(module: String) throws -> [(location: String, line: String)] {
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/\(module)")
    let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    return try files.flatMap { url in
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated().map { ("\(url.lastPathComponent):\($0.offset + 1)", String($0.element)) }
    }
}
