# Tether Plan 2e — Eject, Navigation, Search, Kind Column Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the four spec §5 items that no plan has covered yet:
- an eject button for each phone,
- Back/Forward history with a path pop-up menu,
- a search field that filters the current folder,
- a "Kind" column in list view.

**Architecture:**
- **Eject** is a service operation: `MTPService.ejectDevice(_:)`.
  - It shuts the phone's worker down, which closes the libmtp handle.
  - It hides the phone until it is physically unplugged.
  - It goes over XPC like `releaseDevice`.
  - The app cancels that phone's active transfers before ejecting, and asks first if any are running.
- **History, search and kind** are pure TetherCore types with tests: `NavigationHistory`, `EntryFilter.matching`, `FileKind`. The SwiftUI and AppKit views only wire them up.

**Tech Stack:** Swift 6, SwiftUI, AppKit (NSTableView), UniformTypeIdentifiers, XcodeGen, String Catalogs, Swift Testing, XCUITest.

**Spec:** `docs/superpowers/specs/2026-10-01-tether-design.md` §5:
- "Sidebar: … eject button per device."
- "Toolbar: back/forward; current-folder title with path pop-up menu; … search field (filters the current folder)."
- "sortable list (Name, Size, Date Modified, Kind)."

Follow-ups: `docs/superpowers/notes/2026-10-02-plan2d-followups.md`.

## Global Constraints

- Minimum macOS 15.0. macOS 26+ APIs only behind `if #available(macOS 26, *)`.
- Swift 6 strict concurrency. No warnings in the app build.
- "English and Russian UI."
  - Every new user-facing string goes through the String Catalogs.
    - App code: SwiftUI keys or `String(localized:)`.
    - Package code: `String(localized: …, bundle: .module)`, with `bundle: .module` on the call's first line.
  - Run `scripts/sync-strings.sh` after adding strings, then add Russian (polite «вы», «ёлочки», existing terms). `LocalizationCatalogTests` must pass.
  - Russian Finder terms:
    - Eject → «Извлечь»
    - Back → «Назад»
    - Forward → «Вперёд»
    - Kind → «Тип»
    - Search → «Поиск»
- "Accessibility: VoiceOver labels on all controls and file items." Every new control has a meaningful label. Icon-only buttons name what they act on.
- Diagnostics and logs never contain file names, folder names or device serials.
- Tether never terminates a process the user didn't ask it to. Eject closes Tether's own connection only; it never signals another process.
- Tests never write to or clear the real `~/Library/Caches/dev.tether.Tether`. UI tests pass `-CacheDirectory <temp>`.
- UI tests run with `xcodebuild test -project Tether.xcodeproj -scheme Tether -destination 'platform=macOS' -derivedDataPath DerivedData -only-testing:TetherUITests`. Automation Mode is enabled on the maintainer's Mac. All existing UI tests must keep passing.
- Commit trailer:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01RYh1t7CSXabioJFAfcnW24
  ```

## Review Focus

1. **Eject while transfers are running.** The user confirms first. That phone's queued and running jobs end as *cancelled*, not as failed "phone disconnected" with Retry. Another phone's jobs are untouched. Pinned in Task 1, `ejectCancelsOnlyThatPhonesTransfers`.
2. **Replug after eject.** Unplugging and plugging the phone back in shows it again. A rescan while it is still plugged in does not. Pinned in Task 1, `ejectedDeviceStaysHiddenUntilUnplugged`.
3. **Eject during an open.** The phone is being opened when Eject arrives (just plugged in). The handle that finishes opening is closed, and the phone stays hidden. Pinned in Task 1, `ejectDuringOpenClosesTheHandle`.
4. **History after a reconnect.** After a reconnect, Back/Forward must not navigate into folder handles from the old connection. History resets when the session changes. Pinned in Task 2, `NavigationHistoryTests.resetClearsBothStacks`. BrowserView wiring is checked in Task 2's UI test, which navigates after a back/forward round trip.
5. **Search matching.** It ignores case and diacritics ("фото" finds "Фото.JPG", "cafe" finds "Café.png") and trims whitespace. An empty or whitespace-only query shows everything. Pinned in Task 3, `EntryFilterTests.searchIgnoresCaseAndDiacritics` and `blankQueryShowsAll`.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `Packages/MTPKit/Sources/MTPKit/MTPService.swift` | `ejectDevice(_:)` requirement | 1 |
| `Packages/MTPKit/Sources/MTPKit/LocalMTPService.swift` | `ejected` set, eject, scan skipping | 1 |
| `Packages/MTPKit/Sources/MTPKit/XPC/{XPCMessages,MTPXPCEndpoint,XPCMTPService}.swift` | `.ejectDevice` RPC | 1 |
| `Packages/MTPKit/Sources/TetherCore/{DeviceStore,AppModel,TransferQueue}.swift` | `DeviceStore.eject`, `AppModel.eject`, `TransferQueue.cancelAll(deviceID:)` | 1 |
| `Tether/SidebarView.swift`, `Tether/BrowserCommands.swift`, `Tether/BrowserView.swift` | Eject button + confirmation, File ▸ Eject ⌘E | 1 |
| `Packages/MTPKit/Sources/TetherCore/NavigationHistory.swift` | Back/forward stacks | 2 |
| `Tether/BrowserView.swift`, `Tether/BrowserCommands.swift`, `Tether/FileTableView.swift`, `Tether/FileGridView.swift` | Back/Forward toolbar + Go menu, title path menu | 2 |
| `Packages/MTPKit/Sources/TetherCore/EntryFilter.swift` | `matching(_:query:)` | 3 |
| `Tether/BrowserView.swift`, `Tether/BrowserCommands.swift` | `.searchable`, ⌘F, "No Results" | 3 |
| `Packages/MTPKit/Sources/TetherCore/FileKind.swift` | Kind description | 4 |
| `Tether/FileTableView.swift` | Kind column + sort | 4 |
| `TetherUITests/TetherUITests.swift` | One smoke test per feature | 1–4 |
| Catalogs (`Tether/Localizable.xcstrings`, TetherCore catalog) | New strings en+ru | 1–4 |

---

### Task 1: Eject

**Files:**
- Modify: `Packages/MTPKit/Sources/MTPKit/MTPService.swift`, `LocalMTPService.swift`, `XPC/XPCMessages.swift`, `XPC/MTPXPCEndpoint.swift`, `XPC/XPCMTPService.swift`
- Modify: `Packages/MTPKit/Sources/TetherCore/TransferQueue.swift`, `DeviceStore.swift`, `AppModel.swift`
- Modify: `Tether/SidebarView.swift`, `Tether/BrowserCommands.swift`, `Tether/BrowserView.swift`
- Modify: every `MTPService` test double (`grep -rn ": MTPService" Packages/MTPKit/Tests`)
- Test: create `Packages/MTPKit/Tests/MTPKitTests/EjectTests.swift`; modify `XPCTests.swift`, `TetherCoreTests/AppModelTests.swift`, `TetherCoreTests/DeviceStoreTests.swift`, `TetherUITests/TetherUITests.swift`

**Interfaces:**
- Produces:
  - `MTPService.ejectDevice(_ deviceID: DeviceID) async throws`
  - `TransferQueue.cancelAll(deviceID: DeviceID)`
  - `DeviceStore.eject(_ id: DeviceID) async -> MTPError?`
  - `AppModel.eject(_ id: DeviceID) async -> MTPError?`
  - `AppModel.activeTransferCount(for: DeviceID) -> Int`
  - `BrowserActions.eject: (() -> Void)?`

- [ ] **Step 1: Write the failing service tests**

`Packages/MTPKit/Tests/MTPKitTests/EjectTests.swift`. Follow the setup in `ReleaseTests.swift` for building a `FakeDevice` and a provider, and use its helpers for anything this sketch leaves out:

```swift
import Foundation
import Testing
@testable import MTPKit

@Suite struct EjectTests {
    private func makePhone(_ id: String = "p1") -> FakeDevice {
        FakeDevice(id: id, manufacturer: "Google", model: "Pixel 9")
    }

    @Test func ejectRemovesThePhone() async throws {
        let provider = FakeDeviceProvider()
        provider.attach(makePhone())
        let service = LocalMTPService(provider: provider)
        #expect(try await service.devices().map(\.id) == ["p1"])
        try await service.ejectDevice("p1")
        #expect(try await service.devices().isEmpty)
    }

    @Test func ejectedDeviceStaysHiddenUntilUnplugged() async throws {
        let provider = FakeDeviceProvider()
        let phone = makePhone()
        provider.attach(phone)
        let service = LocalMTPService(provider: provider)
        _ = try await service.devices()
        try await service.ejectDevice("p1")
        await service.rescan()
        #expect(try await service.devices().isEmpty, "still plugged in: must stay ejected")
        #expect(provider.openCount("p1") == 1)
        provider.detach("p1")
        await service.rescan()
        provider.attach(phone)
        await service.rescan()
        #expect(try await service.devices().map(\.id) == ["p1"], "replugged: must come back")
        #expect(provider.openCount("p1") == 2)
    }

    @Test func ejectClosesTheConnection() async throws {
        let provider = FakeDeviceProvider()
        let phone = makePhone()
        provider.attach(phone)
        let service = LocalMTPService(provider: provider)
        _ = try await service.devices()
        try await service.ejectDevice("p1")
        let folder = FolderRef(deviceID: "p1", storageID: 1, folderID: FileEntry.rootID, session: nil)
        await #expect(throws: MTPError.deviceDisconnected) { _ = try await service.list(folder) }
    }

    @Test func ejectDuringOpenClosesTheHandle() async throws {
        let provider = FakeDeviceProvider()
        provider.attach(makePhone())
        provider.holdOpens("p1")
        let service = LocalMTPService(provider: provider)
        let scan = Task { _ = try await service.devices() }
        try await Task.sleep(for: .milliseconds(50))
        try await service.ejectDevice("p1")
        provider.releaseOpens("p1")
        _ = try await scan.value
        #expect(try await service.devices().isEmpty)
    }

    @Test func ejectingAnUnknownPhoneFails() async throws {
        let service = LocalMTPService(provider: FakeDeviceProvider())
        await #expect(throws: MTPError.deviceDisconnected) { try await service.ejectDevice("nope") }
    }

    @Test func ejectingALockedPhoneHidesIt() async throws {
        let provider = FakeDeviceProvider()
        provider.attachUnavailable(AttachedDevice(id: "g1", manufacturer: "Samsung", model: "Galaxy"), error: .deviceLocked)
        let service = LocalMTPService(provider: provider)
        #expect(try await service.devices().count == 1)
        try await service.ejectDevice("g1")
        #expect(try await service.devices().isEmpty)
    }
}
```

Match the real initializers and helpers:
- `FakeDevice` init arguments.
- `holdOpens` / `releaseOpens` semantics. The open must still be blocked when eject arrives. If `holdOpens` takes a count, hold one.
- `FolderRef` init.

Keep every assertion.

In `ejectDuringOpenClosesTheHandle`, also check that the held handle was closed when the open finished, if `FakeDevice` exposes a closed flag (e.g. `phone.isClosed`). If it doesn't, add a minimal `public private(set) var closeCount` to `FakeDevice` and assert that it is 1.

In `XPCTests.swift`, add `ejectCrossesXPC`, following `releaseCrossesXPC`. Eject over the XPC client, then the device list over XPC is empty.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --package-path Packages/MTPKit --filter "EjectTests|XPCTests"`
Expected: compile error, `value of type 'LocalMTPService' has no member 'ejectDevice'`.

- [ ] **Step 3: Implement the service side**

`MTPService.swift`, in the protocol after `releaseDevice`:

```swift
    /// Closes Tether's connection to the phone and hides it until it is unplugged (Finder's Eject).
    func ejectDevice(_ deviceID: DeviceID) async throws
```

`LocalMTPService.swift`:

```swift
    /// Transport keys the user ejected; skipped by scans until a scan sees them unplugged.
    private var ejected: Set<DeviceID> = []

    public func ejectDevice(_ deviceID: DeviceID) async throws {
        await ensureScanned()
        let key = key(for: deviceID)
        guard infos[key] != nil || opening[key] != nil else { throw MTPError.deviceDisconnected }
        ejected.insert(key)
        workers.removeValue(forKey: key)?.shutdown(reason: .deviceDisconnected)
        infos[key] = nil
        publicIDs[key] = nil
        log.record("Device ejected", category: "device")
        emit(.devicesChanged(sortedDevices()))
    }
```

In `performScan()`, right after `lastAttached = …`:

```swift
        ejected.formIntersection(lastAttached) // unplugged phones come back next time they're attached
```

Skip ejected phones in the open loop:

```swift
        for device in attached where workers[device.id] == nil && opening[device.id] == nil && !ejected.contains(device.id) {
```

Add `&& !ejected.contains(device.id)` to the `current` reentrancy check, so an eject during an open closes the fresh handle (`guard current else { opened.close(); continue }`) and doesn't record a failure state.

XPC:
- In `XPCMessages.swift`, add `case ejectDevice(deviceID: DeviceID)` to `XPCRequest`.
- In `MTPXPCEndpoint.swift`, add `case .ejectDevice(let id): try await service.ejectDevice(id)` and return `.ok`, mirroring `.releaseDevice`.
- In `XPCMTPService.swift`, add:

```swift
    public func ejectDevice(_ deviceID: DeviceID) async throws {
        _ = try await send(.ejectDevice(deviceID: deviceID))
    }
```

Add `func ejectDevice(_ deviceID: DeviceID) async throws { try await base.ejectDevice(deviceID) }` to `FlakyService`, and the equivalent to every other test double the compiler lists.

- [ ] **Step 4: Run the service tests**

Run: `swift test --package-path Packages/MTPKit --filter "EjectTests|XPCTests"`
Expected: PASS.

- [ ] **Step 5: Write the failing app-model tests**

In `TetherCoreTests/AppModelTests.swift`, using the file's `makeModel` helper (temp cache directories):

```swift
    @Test func ejectCancelsOnlyThatPhonesTransfers() async throws {
        // Two phones with slow transfers; each keeps one job active.
        let provider = FakeDeviceProvider()
        let slow = { (id: String) in FakeDevice(id: id, manufacturer: "Google", model: "Pixel", chunkSize: 1024, chunkDelay: 0.05) }
        let a = slow("a"), b = slow("b")
        let fileA = a.addFile("big.bin", data: Data(count: 1_000_000))
        let fileB = b.addFile("big.bin", data: Data(count: 1_000_000))
        provider.attach(a); provider.attach(b)
        let model = makeModel(LocalMTPService(provider: provider))
        await model.devices.reloadDevices()
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let jobA = model.transfers.enqueueDownload(fileA, deviceID: "a", into: dir)
        let jobB = model.transfers.enqueueDownload(fileB, deviceID: "b", into: dir)
        try await eventually { model.activeTransferCount(for: "a") == 1 && model.activeTransferCount(for: "b") == 1 }

        let error = await model.eject("a")

        #expect(error == nil)
        #expect(model.transfers.jobs.first { $0.id == jobA }?.state == .cancelled)
        #expect(model.transfers.jobs.first { $0.id == jobB }?.isActive == true)
        #expect(model.devices.devices.map(\.id) == ["b"])
    }
```

Adapt this to the real signatures:
- `makeModel`'s parameter.
- `addFile`'s return value (it must yield a `FileEntry`).
- `enqueueDownload`'s return value (a job ID) and its `completion:` argument.

Keep the assertions.

In `DeviceStoreTests.swift`, add `ejectReloadsDevices`: after `store.eject("p1")`, `store.devices` is empty and the function returned `nil`.

- [ ] **Step 6: Run them to verify they fail**

Run: `swift test --package-path Packages/MTPKit --filter "AppModelTests|DeviceStoreTests"`
Expected: compile error, no member `eject` / `activeTransferCount`.

- [ ] **Step 7: Implement the app model**

`TransferQueue.swift`:

```swift
    /// Cancels every queued or running job for one phone (used before ejecting it).
    public func cancelAll(deviceID: DeviceID) {
        for job in jobs where job.isActive && job.deviceID == deviceID { cancel(job.id) }
    }
```

`DeviceStore.swift`:

```swift
    /// Closes Tether's connection to the phone; it disappears from the list until it is unplugged and plugged in again.
    public func eject(_ id: DeviceID) async -> MTPError? {
        var failure: MTPError?
        do { try await service.ejectDevice(id) } catch { failure = MTPError.from(error) }
        await reloadDevices()
        return failure
    }
```

`AppModel.swift`:

```swift
    public func activeTransferCount(for deviceID: DeviceID) -> Int {
        transfers.jobs.filter { $0.isActive && $0.deviceID == deviceID }.count
    }

    /// Stops this phone's transfers and previews, then ejects it.
    public func eject(_ deviceID: DeviceID) async -> MTPError? {
        transfers.cancelAll(deviceID: deviceID)
        previews.cancelAll()
        return await devices.eject(deviceID)
    }
```

`previews.cancelAll()` cancels every preview download, not just this phone's. This is acceptable because only one Quick Look panel exists. Leave a comment saying so.

- [ ] **Step 8: Wire the UI**

`SidebarView.swift`: in the `.ready` and `.unavailable` device rows, put the device `Label` in an `HStack` with a `Spacer()` and an eject button:

```swift
private struct EjectButton: View {
    @Environment(AppModel.self) private var model
    let device: DeviceInfo
    @State private var confirming = false

    var body: some View {
        Button {
            if model.activeTransferCount(for: device.id) > 0 { confirming = true } else { eject() }
        } label: {
            Image(systemName: "eject")
        }
        .buttonStyle(.borderless)
        .help(String(localized: "Eject \(device.displayName)"))
        .accessibilityLabel(String(localized: "Eject \(device.displayName)"))
        .confirmationDialog(String(localized: "Eject “\(device.displayName)”?"), isPresented: $confirming) {
            Button("Eject", role: .destructive) { eject() }
        } message: {
            Text("\(model.activeTransferCount(for: device.id)) transfers will stop.")
        }
    }

    private func eject() { Task { _ = await model.eject(device.id) } }
}
```

`BrowserCommands.swift`:
- Add `var eject: (() -> Void)?` to `BrowserActions`.
- In `CommandGroup(after: .newItem)`, after Delete, add a `Divider()` and `Button("Eject") { actions?.eject?() }.keyboardShortcut("e").disabled(actions?.eject == nil)`.

`BrowserView.swift`:
- Set `eject` in the focused `BrowserActions` to eject `selection.deviceID`.
- If the device has active transfers, show the same confirmation from the browser instead. Use a `@State var confirmingEject` with the same dialog text, so the two share the catalog keys.

Run `scripts/sync-strings.sh` and add Russian:
- `Eject %@` → «Извлечь %@»
- `Eject “%@”?` → «Извлечь «%@»?»
- `Eject` → «Извлечь»
- `%lld transfers will stop.` (plural):
  - one: «%lld передача будет остановлена.»
  - few: «%lld передачи будут остановлены.»
  - many: «%lld передач будут остановлены.»
  - other: «%lld передачи будут остановлены.»
  - English one: «%lld transfer will stop.»

- [ ] **Step 9: UI test**

In `TetherUITests.swift`:

```swift
    func testEject() {
        launchToRoot()
        app.outlines["sidebar"].buttons["Eject Pixel 9"].click()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.outlines["sidebar"].staticTexts["Pixel 9"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.outlines["sidebar"].staticTexts["Galaxy S25"].exists, "the other phone must stay")
    }
```

If a query doesn't match, print `app.debugDescription` once and fix the query.

- [ ] **Step 10: Run everything**

Run: `swift test --package-path Packages/MTPKit`. Expected: all pass.
Run: `scripts/sync-strings.sh` twice. Expected: the second run shows no catalog diff.
Run: `xcodegen generate && xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Debug -derivedDataPath DerivedData build 2>&1 | grep -E "warning:|error:|BUILD"`. Expected: `** BUILD SUCCEEDED **` and no Swift warnings.
Run the UI tests (Global Constraints command). Expected: all pass, including `testEject`.

- [ ] **Step 11: Commit**

```bash
git add Packages/MTPKit Tether TetherUITests
git commit -m "feat: eject phones from the sidebar and File menu (⌘E)"
```

---

### Task 2: Back/Forward history and the path menu

**Files:**
- Create: `Packages/MTPKit/Sources/TetherCore/NavigationHistory.swift`
- Test: create `Packages/MTPKit/Tests/TetherCoreTests/NavigationHistoryTests.swift`; modify `TetherUITests/TetherUITests.swift`
- Modify: `Tether/BrowserView.swift`, `Tether/BrowserCommands.swift`, `Tether/FileTableView.swift` and `Tether/FileGridView.swift` (only where their `goUp` action plumbing is touched)

**Interfaces:**
- Produces:
  - `NavigationHistory<Location: Equatable & Sendable>`, which has:
    - `current: Location`
    - `canGoBack` / `canGoForward`
    - `visit(_:)`, `goBack()`, `goForward()`, `reset(to:)`
  - `BrowserActions.goBack` / `goForward: (() -> Void)?`.

- [ ] **Step 1: Write the failing tests**

`NavigationHistoryTests.swift`:

```swift
import Testing
@testable import TetherCore

@Suite struct NavigationHistoryTests {
    @Test func startsWithNoHistory() {
        let history = NavigationHistory(start: [Int]())
        #expect(history.current == [])
        #expect(!history.canGoBack && !history.canGoForward)
    }

    @Test func backAndForwardRetraceVisits() {
        var history = NavigationHistory(start: [Int]())
        history.visit([1])
        history.visit([1, 2])
        history.goBack()
        #expect(history.current == [1])
        history.goBack()
        #expect(history.current == [])
        #expect(!history.canGoBack)
        history.goForward()
        history.goForward()
        #expect(history.current == [1, 2])
        #expect(!history.canGoForward)
    }

    @Test func visitingClearsForward() {
        var history = NavigationHistory(start: [Int]())
        history.visit([1])
        history.goBack()
        history.visit([3])
        #expect(!history.canGoForward)
        #expect(history.current == [3])
    }

    @Test func revisitingTheCurrentLocationIsANoOp() {
        var history = NavigationHistory(start: [Int]())
        history.visit([1])
        history.visit([1])
        history.goBack()
        #expect(history.current == [])
    }

    @Test func goingPastTheEndsDoesNothing() {
        var history = NavigationHistory(start: [Int]())
        history.goBack()
        history.goForward()
        #expect(history.current == [])
    }

    @Test func resetClearsBothStacks() {
        var history = NavigationHistory(start: [Int]())
        history.visit([1])
        history.visit([1, 2])
        history.goBack()
        history.reset(to: [])
        #expect(history.current == [])
        #expect(!history.canGoBack && !history.canGoForward)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --package-path Packages/MTPKit --filter NavigationHistoryTests`
Expected: compile error, `cannot find 'NavigationHistory' in scope`.

- [ ] **Step 3: Implement**

`NavigationHistory.swift`:

```swift
/// Finder-style Back/Forward: visiting a new location clears Forward.
public struct NavigationHistory<Location: Equatable & Sendable>: Sendable {
    public private(set) var current: Location
    private var back: [Location] = []
    private var forward: [Location] = []

    public init(start: Location) { current = start }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    public mutating func visit(_ location: Location) {
        guard location != current else { return }
        back.append(current)
        current = location
        forward.removeAll()
    }

    public mutating func goBack() {
        guard let previous = back.popLast() else { return }
        forward.append(current)
        current = previous
    }

    public mutating func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(current)
        current = next
    }

    /// Forgets all history (used when the phone reconnects: old folder handles are meaningless).
    public mutating func reset(to location: Location) {
        current = location
        back.removeAll()
        forward.removeAll()
    }
}
```

Run: `swift test --package-path Packages/MTPKit --filter NavigationHistoryTests`. Expected: PASS.

- [ ] **Step 4: Wire the browser**

`BrowserView.swift`:
- Replace `@State private var path: [FileEntry] = []` with `@State private var history = NavigationHistory(start: [FileEntry]())`, and add a computed `private var path: [FileEntry] { history.current }`. Every reader of `path` keeps working.
- Change the writers:
  - `open(entry)` → `history.visit(path + [entry])`
  - `goUp()` → `if !path.isEmpty { history.visit(Array(path.dropLast())) }`. This is Finder's Enclosing Folder; it is recorded in history.
  - The session `onChange` → `history.reset(to: [])` (it was `path = []`).
- Wherever `pathSession` is set alongside `path`, keep setting it the same way.
- Add `goBack()` and `goForward()`, each calling the history method.
- Toolbar: in the `.navigation` placement, replace the single Back button with a `ControlGroup`, or two buttons, holding:
  - `Button(action: goBack) { Label("Back", systemImage: "chevron.left") }.disabled(!history.canGoBack || isEditingName).help("Back")`
  - the same for Forward (`chevron.right`, `"Forward"`, `!history.canGoForward`).
  - Enclosing Folder stays in the Go menu (⌘↑) and in the existing `goUp` action. It is no longer a toolbar button, matching Finder.
- Path pop-up menu: on the view, add `.toolbarTitleMenu { pathMenu }`:

```swift
    @ViewBuilder private var pathMenu: some View {
        Button(model.devices.storage(for: folder)?.name ?? String(localized: "Phone")) { history.visit([]) }
        ForEach(Array(path.dropLast().enumerated()), id: \.offset) { index, entry in
            Button(entry.name) { history.visit(Array(path.prefix(index + 1))) }
        }
    }
```

  The storage root comes first, then each ancestor folder. The current folder is left out, because it is already the title. Use `Button(verbatim:)` or `Text(verbatim:)` for folder names, so a name never becomes a catalog key. The storage-name button falls back to the existing "Phone" key.

`BrowserCommands.swift`:
- Add `var goBack: (() -> Void)?` and `var goForward: (() -> Void)?` to `BrowserActions`.
- In `CommandMenu("Go")`, before Enclosing Folder:

```swift
            Button("Back") { actions?.goBack?() }
                .keyboardShortcut("[")
                .disabled(actions?.goBack == nil)
            Button("Forward") { actions?.goForward?() }
                .keyboardShortcut("]")
                .disabled(actions?.goForward == nil)
```

`BrowserView` sets `goBack` / `goForward` in its focused actions when `canGoBack` / `canGoForward`, and passes `nil` while a name is being edited, like `goUp`.

Run `scripts/sync-strings.sh` and add Russian: `Forward` → «Вперёд». "Back" already exists as «Назад».

- [ ] **Step 5: UI test**

```swift
    func testBackAndForward() {
        launchToRoot()
        cell("DCIM").doubleClick()
        XCTAssertTrue(cell("Camera").waitForExistence(timeout: 5))
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(cell("notes.txt").waitForExistence(timeout: 5))
        app.typeKey("]", modifierFlags: .command)
        XCTAssertTrue(cell("Camera").waitForExistence(timeout: 5))
        cell("Camera").doubleClick()   // navigating after a round trip still uses live handles
        XCTAssertTrue(cell("IMG_0001.jpg").waitForExistence(timeout: 5))
    }
```

- [ ] **Step 6: Run everything and commit**

Run the same four checks as in Task 1, Step 10. All must pass.

```bash
git add Packages/MTPKit Tether TetherUITests
git commit -m "feat: Back/Forward history (⌘[ ⌘]) and a path menu on the folder title"
```

---

### Task 3: Search in the current folder

**Files:**
- Modify: `Packages/MTPKit/Sources/TetherCore/EntryFilter.swift`
- Test: `Packages/MTPKit/Tests/TetherCoreTests/EntryFilterTests.swift`, `TetherUITests/TetherUITests.swift`
- Modify: `Tether/BrowserView.swift`, `Tether/BrowserCommands.swift`

**Interfaces:**
- Produces:
  - `EntryFilter.matching(_ entries: [FileEntry], query: String) -> [FileEntry]`
  - `BrowserActions.find: (() -> Void)?`

- [ ] **Step 1: Write the failing tests**

Add to `EntryFilterTests.swift`, reusing the file's existing entry-building helper. If it has none, build entries with `FileEntry(objectID:parentID:storageID:name:size:modified:isFolder:)`:

```swift
    @Test func searchIgnoresCaseAndDiacritics() {
        let entries = ["Фото.JPG", "Café.png", "notes.txt"].enumerated().map { entry($0.element, id: UInt32($0.offset)) }
        #expect(EntryFilter.matching(entries, query: "фото").map(\.name) == ["Фото.JPG"])
        #expect(EntryFilter.matching(entries, query: "cafe").map(\.name) == ["Café.png"])
        #expect(EntryFilter.matching(entries, query: "  NOTES ").map(\.name) == ["notes.txt"])
    }

    @Test func blankQueryShowsAll() {
        let entries = [entry("a", id: 1), entry("b", id: 2)]
        #expect(EntryFilter.matching(entries, query: "").count == 2)
        #expect(EntryFilter.matching(entries, query: "   ").count == 2)
    }

    @Test func searchMatchesAnywhereInTheName() {
        let entries = [entry("IMG_0012.jpg", id: 1), entry("Download", id: 2)]
        #expect(EntryFilter.matching(entries, query: "0012").map(\.name) == ["IMG_0012.jpg"])
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --package-path Packages/MTPKit --filter EntryFilterTests`
Expected: compile error, `type 'EntryFilter' has no member 'matching'`.

- [ ] **Step 3: Implement**

In `EntryFilter.swift`:

```swift
    /// Entries whose name contains `query`, ignoring case and diacritics, in the user's locale. A blank query matches all.
    public static func matching(_ entries: [FileEntry], query: String) -> [FileEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter { $0.name.localizedStandardContains(needle) }
    }
```

`EntryFilter.swift` needs `import Foundation` if it lacks it. Run the tests again. Expected: PASS.

- [ ] **Step 4: Wire the browser**

`BrowserView.swift`:
- Add `@State private var searchText = ""` and `@FocusState private var searchFocused: Bool`.
- `visibleEntries` becomes `EntryFilter.matching(EntryFilter.visible(allEntries, showHidden: showHiddenFiles), query: searchText)`. Name-clash checks still use `allEntries`, which is unchanged.
- On the view, add `.searchable(text: $searchText, placement: .toolbar, prompt: Text("Search in This Folder"))` and `.searchFocused($searchFocused)`.
- In the existing `onChange(of: folder)` and the session `onChange`, add `searchText = ""`. Searching is per folder, as in Finder's "This Folder" scope.
- In `overlay(for:)`, before the "Empty Folder" case, add: `else if visibleEntries.isEmpty && !searchText.trimmingCharacters(in: .whitespaces).isEmpty { ContentUnavailableView.search(text: searchText) }`. The system view is already localized.
- The subtitle count (`%lld items`) already counts `visibleEntries`, so it shows the number of matches. Leave it.
- Set `find: { searchFocused = true }` in the focused `BrowserActions`.

`BrowserCommands.swift`:
- Add `var find: (() -> Void)?`.
- In `CommandGroup(after: .textEditing)`, add `Button("Find") { actions?.find?() }.keyboardShortcut("f").disabled(actions?.find == nil)`. If an Edit ▸ Find menu already exists, put the item there instead.

Run `scripts/sync-strings.sh` and add Russian:
- `Search in This Folder` → «Поиск в этой папке»
- `Find` → «Найти»

- [ ] **Step 5: UI test**

```swift
    func testSearchFiltersTheFolder() {
        launchToRoot()
        app.typeKey("f", modifierFlags: .command)
        app.typeText("note")
        XCTAssertTrue(cell("notes.txt").waitForExistence(timeout: 5))
        XCTAssertFalse(cell("DCIM").exists)
        cell("notes.txt").click()   // search keeps working with the table
        app.typeKey(.escape, modifierFlags: [])
    }
```

If Escape doesn't clear the field when the table has focus, that's fine; the test ends there. Don't add app code just for it.

- [ ] **Step 6: Run everything and commit**

Run the same four checks as Task 1, Step 10.

```bash
git add Packages/MTPKit Tether TetherUITests
git commit -m "feat: search the current folder (⌘F)"
```

---

### Task 4: Kind column

**Files:**
- Create: `Packages/MTPKit/Sources/TetherCore/FileKind.swift`
- Test: create `Packages/MTPKit/Tests/TetherCoreTests/FileKindTests.swift`; modify `TetherUITests/TetherUITests.swift`
- Modify: `Tether/FileTableView.swift` (`Column`, `viewFor`, `resort`)

**Interfaces:**
- Produces: `FileKind.description(for entry: FileEntry) -> String`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
import UniformTypeIdentifiers
import MTPKit
@testable import TetherCore

@Suite struct FileKindTests {
    private func entry(_ name: String, folder: Bool = false) -> FileEntry {
        FileEntry(objectID: 1, parentID: FileEntry.rootID, storageID: 1, name: name, size: 1, modified: nil, isFolder: folder)
    }

    @Test func folderIsFolder() {
        #expect(FileKind.description(for: entry("DCIM", folder: true)) == UTType.folder.localizedDescription)
    }

    @Test func knownExtensionUsesTheSystemDescription() {
        #expect(FileKind.description(for: entry("IMG_0001.jpg")) == UTType.jpeg.localizedDescription)
        #expect(FileKind.description(for: entry("notes.TXT")) == UTType.plainText.localizedDescription)
    }

    @Test func unknownOrMissingExtensionIsDocument() {
        let document = FileKind.description(for: entry("README"))
        #expect(!document.isEmpty)
        #expect(FileKind.description(for: entry("data.zzqq")) == document)
    }

    @Test func russianDocumentWord() {
        let ru = Bundle(url: Bundle.module.url(forResource: "ru", withExtension: "lproj")!)!
        #expect(ru.localizedString(forKey: "Document", value: "?", table: nil) == "Документ")
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --package-path Packages/MTPKit --filter FileKindTests`
Expected: compile error, `cannot find 'FileKind' in scope`.

- [ ] **Step 3: Implement**

`FileKind.swift`:

```swift
import Foundation
import MTPKit
import UniformTypeIdentifiers

/// The "Kind" column text: the system's localized type description, like Finder.
public enum FileKind {
    public static func description(for entry: FileEntry) -> String {
        if entry.isFolder { return UTType.folder.localizedDescription ?? String(localized: "Folder", bundle: .module) }
        let ext = (entry.name as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic, let text = type.localizedDescription {
            return text
        }
        return String(localized: "Document", bundle: .module)
    }
}
```

`UTType(filenameExtension:)` returns a *dynamic* type for unknown extensions. That type's description is a generic phrase, which `!type.isDynamic` routes to "Document" instead.

Run `scripts/sync-strings.sh` and add Russian to the TetherCore catalog:
- `Document` → «Документ»
- `Folder` → «Папка»

Run the tests again. Expected: PASS. If `UTType.folder.localizedDescription` returns nil in the test environment, the folder test compares against the fallback. Make the test use `FileKind`'s actual fallback rule rather than hard-coding a string.

- [ ] **Step 4: Add the column**

In `FileTableView.swift`:
- `Column`: `case name, size, kind, modified`. The order follows Finder: Name, Size, Kind, Date Modified. Add:
  - title: `case .kind: String(localized: "Kind")`
  - width: `case .kind: 140`
- `tableView(_:viewFor:row:)`: add `case .kind: cell.textField?.stringValue = FileKind.description(for: entry)`.
- `resort()`: add a sort for the kind key, comparing the two descriptions with `localizedStandardCompare` and falling back to name:

```swift
                case Column.kind.rawValue:
                    FileKind.description(for: a) != FileKind.description(for: b)
                        ? FileKind.description(for: a).localizedStandardCompare(FileKind.description(for: b)) == .orderedAscending
                        : a.name.localizedStandardCompare(b.name) == .orderedAscending
```

Users may have saved column layouts. Check that the table doesn't persist its columns with `autosaveName`; if it does, make sure the new column still appears.

Run `scripts/sync-strings.sh` and add Russian: `Kind` → «Тип».

- [ ] **Step 5: UI test**

```swift
    func testKindColumn() {
        launchToRoot()
        XCTAssertTrue(table.buttons["Kind"].exists || table.staticTexts["Kind"].exists, "Kind column header missing")
        XCTAssertTrue(table.staticTexts.matching(NSPredicate(format: "value ==[c] %@ OR label ==[c] %@", "Folder", "Folder")).firstMatch.exists)
    }
```

Find the real column-header and cell element types through `app.debugDescription` once. In `testRussianUI`, add a check that the header «Тип» exists.

- [ ] **Step 6: Run everything and commit**

Run the same four checks as Task 1, Step 10.

```bash
git add Packages/MTPKit Tether TetherUITests
git commit -m "feat: Kind column in list view"
```

**Manual checklist (for the human):**
1. Eject Pixel 9 from the sidebar: it disappears. Unplug the real phone and plug it back in: it reappears. Start a large download, then press Eject: a confirmation appears, and confirming leaves the job "Cancelled".
2. Browse two folders deep, then use ⌘[, ⌘] and the toolbar arrows. Click the folder title: the menu lists the storage and each parent folder.
3. ⌘F, then type part of a name: only matches show, and the subtitle shows the match count. Search for something with no match: "No Results".
4. List view: the Kind column shows "Folder", "JPEG image" and so on, and sorts. In Russian the values are «Папка», «Изображение JPEG».

---

## Spec coverage

| Spec | Task |
|---|---|
| §5 Sidebar: eject button per device | 1 |
| §5 Toolbar: back/forward | 2 |
| §5 Toolbar: current-folder title with path pop-up menu | 2 |
| §5 Toolbar: search field (filters the current folder) | 3 |
| §5 Content: sortable list (Name, Size, Date Modified, Kind) | 4 |
| §5 Localization / Accessibility for the new controls | 1–4 |

After this plan, every §5 item is covered. Next is Plan 3 (distribution).
