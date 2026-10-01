import XCTest

/// Smoke flows against the in-memory demo phones (`-UseFakeDevices YES`). Nothing touches real caches or Downloads.
@MainActor
final class TetherUITests: XCTestCase {
    private var app: XCUIApplication!
    private var downloads: URL!
    private var caches: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appending(path: "TetherUITests-\(UUID().uuidString)")
        downloads = root.appending(path: "Downloads")
        caches = root.appending(path: "Caches")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments = [
            "-UseFakeDevices", "YES",
            "-CacheDirectory", caches.path,
            "-downloadFolderPath", downloads.path,
            "-conflictDefault", "keepBoth",
            "-showHiddenFiles", "NO",
            "-viewMode", "list",
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(en)",
        ]
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: downloads.deletingLastPathComponent())
    }

    private var table: XCUIElement { app.tables["fileTable"] }

    /// The name-column cell of a row. A plain `[name]` subscript also matches the name's StaticText by value
    /// (no label), so match on the cell's VoiceOver label ("name, size" / "name, folder") instead.
    private func cell(_ name: String) -> XCUIElement {
        table.cells.matching(NSPredicate(format: "label BEGINSWITH %@", name + ", ")).firstMatch
    }

    private func launchToRoot() {
        app.launch()
        XCTAssertTrue(cell("notes.txt").waitForExistence(timeout: 10), "Pixel 9's root folder didn't load")
    }

    func testBrowse() {
        launchToRoot()
        cell("DCIM").doubleClick()
        XCTAssertTrue(cell("Camera").waitForExistence(timeout: 5))
        cell("Camera").doubleClick()
        XCTAssertTrue(cell("IMG_0012.jpg").waitForExistence(timeout: 5))
        app.typeKey(.upArrow, modifierFlags: .command)
        XCTAssertTrue(cell("Camera").waitForExistence(timeout: 5))
    }

    func testDownload() throws {
        launchToRoot()
        cell("notes.txt").rightClick()
        // "Download" also exists (disabled, zero-size) in the menu bar, so address the context-menu item by identifier.
        app.menuItems["downloadFromMenu"].click()
        let file = downloads.appending(path: "notes.txt")
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: file.path), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Hello from Tether")
    }

    func testUpload() throws {
        let source = downloads.deletingLastPathComponent().appending(path: "upload-me.txt")
        try "from the Mac".write(to: source, atomically: true, encoding: .utf8)
        launchToRoot()
        app.toolbars.buttons["Upload"].click()
        let panel = app.windows["open-panel"] // NSOpenPanel is its own window, not a sheet
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(source.path + "\n")
        let ok = panel.buttons["OKButton"]
        XCTAssertTrue(ok.waitForExistence(timeout: 5))
        ok.click()
        XCTAssertTrue(cell("upload-me.txt").waitForExistence(timeout: 10))
    }

    func testRename() {
        launchToRoot()
        cell("notes.txt").click()
        app.typeKey(.return, modifierFlags: [])
        app.typeKey("a", modifierFlags: .command)
        app.typeText("renamed.txt\n")
        XCTAssertTrue(cell("renamed.txt").waitForExistence(timeout: 5))
        XCTAssertFalse(cell("notes.txt").exists)
    }

    func testRenameUpdatesVoiceOverLabel() {
        launchToRoot()
        cell("notes.txt").click()
        app.typeKey(.return, modifierFlags: [])
        app.typeKey("a", modifierFlags: .command)
        app.typeText("spoken.txt\n")
        let renamed = cell("spoken.txt")
        XCTAssertTrue(renamed.waitForExistence(timeout: 5))
        XCTAssertTrue(renamed.label.hasPrefix("spoken.txt, "), "VoiceOver label is stale: \(renamed.label)")
    }

    func testDelete() {
        launchToRoot()
        cell("notes.txt").click()
        app.typeKey(.delete, modifierFlags: .command)
        let confirm = app.dialogs.buttons["Delete"].exists ? app.dialogs.buttons["Delete"] : app.sheets.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: cell("notes.txt"))
        waitForExpectations(timeout: 5)
    }

    func testLockedPhoneShowsUnlockGuidance() {
        launchToRoot()
        app.outlines["sidebar"].staticTexts["Galaxy S25"].click()
        // The locked row has no storage, so it isn't selectable; its hint lives in the sidebar row (as a value).
        let hint = app.outlines["sidebar"].staticTexts.matching(NSPredicate(format: "value CONTAINS[c] 'Unlock' OR label CONTAINS[c] 'Unlock'")).firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 5))
    }

    func testFileCellsHaveVoiceOverLabels() {
        launchToRoot()
        XCTAssertEqual(cell("DCIM").label, "DCIM, folder")
        XCTAssertTrue(cell("notes.txt").label.hasPrefix("notes.txt, "))
    }

    func testRussianUI() {
        app.launchArguments = app.launchArguments.map { $0 == "(en)" ? "(ru)" : $0 }
        app.launch()
        XCTAssertTrue(cell("notes.txt").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Устройства"].exists, "Sidebar section isn't Russian")
        XCTAssertTrue(app.toolbars.buttons["Новая папка"].exists, "Toolbar isn't Russian")
        XCTAssertEqual(cell("DCIM").label, "DCIM, папка")
    }
}
