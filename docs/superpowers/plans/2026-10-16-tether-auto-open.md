# Auto-open Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tether opens and comes to the front by itself when an Android phone in File transfer (MTP) mode is plugged in. The feature is off by default and turned on in Settings.

**Architecture:** A tiny login-item app, `TetherLauncher`, is embedded at `Tether.app/Contents/Library/LoginItems/` and registered with `SMAppService.loginItem`. It watches IOKit USB arrivals, decides from descriptors alone whether the new device is a phone in File transfer mode, and opens the containing `Tether.app`. The decision logic (descriptor matching, ignoring wakes and reconnects) is a pure Swift target, `PhoneDetection`. The registration logic, including re-registering after an update, is `AutoOpenController` in `TetherCore`. Both have unit tests.

**Tech Stack:** Swift 6, SwiftUI, IOKit, ServiceManagement, Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-16-auto-open-design.md`. Read its behaviour table and its "Spike results" section before starting.

## Global Constraints

- macOS 15.0 deployment target, Swift 6.0, hardened runtime, ad-hoc signing (`CODE_SIGN_IDENTITY: "-"`), no sandbox. Match `project.yml`.
- `TetherLauncher` must not link libmtp, libusb, MTPKit or TetherCore. Its only package dependency is `PhoneDetection`.
- No polling timers in the launcher. Detection is IOKit-notification-driven.
- Off by default. The toggle reflects `SMAppService.status`, not a stored bool.
- Every user-facing string in English and Russian. Run `scripts/sync-strings.sh` and fill in `ru`. The `LocalizationCatalogTests` suite must pass.
- The `-UseFakeDevices YES` mode never touches `SMAppService`, and the toggle is hidden there.
- CI fails on any compiler warning (`.github/workflows/ci.yml`).
- Bundle IDs: app `dev.tether.Tether`, launcher `dev.tether.Tether.Launcher`.

## Review Focus

1. **After a Sparkle update** the old registration silently fails to spawn (spike). The first launch of a new version must re-register. Pinned by `repairReregistersAfterVersionChange` (Task 3).
2. **The user turns the item off in System Settings → Login Items** while Tether is open. Settings must show it as off or needing approval when reopened, not stale "on". Pinned by `refreshPicksUpExternalChange` (Task 3).
3. **A phone already connected when the launcher starts** (login, or just after turning the toggle on) must not open Tether. Pinned by `existingDevicesAtStartAreIgnored` (Task 2) plus the launcher draining its first iterator without handling it (Task 4).
4. **Interfaces attach after the device-arrival notification** (seen at about 1.5 s on the iQOO). A phone whose MTP interface shows up late must still trigger. Covered by Task 4's read-then-retry, and a checklist row (Task 6).
5. **A user who deliberately replugs within 1 s** is treated as a reconnect and ignored (grace lowered from 5 s after the real-phone test). That's an accepted trade-off from the spec. Pinned by `quickReplugOfFileTransferPhoneIsIgnored` (Task 2) so nobody "fixes" it by accident.

---

### Task 1: `PhoneDetection` — is this a phone in File transfer mode?

**Files:**
- Modify: `Packages/MTPKit/Package.swift`: add the library product `PhoneDetection`, the target `PhoneDetection` (no dependencies, no resources) and the test target `PhoneDetectionTests`.
- Create: `Packages/MTPKit/Sources/PhoneDetection/FileTransferMatch.swift`
- Test: `Packages/MTPKit/Tests/PhoneDetectionTests/FileTransferMatchTests.swift`

**Interfaces:**
- Produces:
  - `public struct USBInterfaceInfo: Sendable, Equatable { public let interfaceClass: Int; public let subclass: Int; public let protocolCode: Int; public let name: String?; public init(_ interfaceClass: Int, _ subclass: Int, _ protocolCode: Int, name: String?) }`
  - `public enum FileTransferMatch { public static func isFileTransfer(_ interfaces: [USBInterfaceInfo]) -> Bool }`

- [ ] **Step 1: Write the failing tests** (Swift Testing, `@Suite struct FileTransferMatchTests`)

```swift
@Test func iqooFileTransferMatches() {      // real descriptors from the spike
    #expect(FileTransferMatch.isFileTransfer([.init(6, 1, 1, name: "MTP"), .init(8, 6, 80, name: "Mass Storage"),
                                              .init(255, 66, 1, name: "ADB Interface")]))
}
@Test func vendorClassMTPMatches() { #expect(FileTransferMatch.isFileTransfer([.init(255, 255, 0, name: "MTP")])) }
@Test func nameIsCaseInsensitive() { #expect(FileTransferMatch.isFileTransfer([.init(255, 255, 0, name: "mtp")])) }
@Test func chargingOnlyWithADBDoesNotMatch() {
    #expect(!FileTransferMatch.isFileTransfer([.init(255, 66, 1, name: "ADB Interface")]))
}
@Test func plainStillImageDoesNotMatch() {  // iPhone / camera PTP
    #expect(!FileTransferMatch.isFileTransfer([.init(6, 1, 1, name: nil)]))
    #expect(!FileTransferMatch.isFileTransfer([.init(6, 1, 1, name: "PTP")]))
}
@Test func mtpNameOnOtherClassDoesNotMatch() {
    #expect(!FileTransferMatch.isFileTransfer([.init(8, 6, 80, name: "MTP Storage")]))
}
@Test func noInterfacesDoesNotMatch() { #expect(!FileTransferMatch.isFileTransfer([])) }
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `cd Packages/MTPKit && swift test --filter FileTransferMatchTests`
Expected: compile failure, `cannot find 'FileTransferMatch'`.

- [ ] **Step 3: Implement `FileTransferMatch.isFileTransfer`.** The rule: some interface has class `6` or `255` **and** a name containing "MTP", compared case-insensitively.

- [ ] **Step 4: Run them and confirm they pass.** Same command. Expected: 7 tests pass.

- [ ] **Step 5: Commit** `feat(detection): match phones in File transfer mode by USB descriptors`

---

### Task 2: `PhoneDetection` — `ArrivalFilter` (wakes, reconnects, duplicates)

**Files:**
- Create: `Packages/MTPKit/Sources/PhoneDetection/ArrivalFilter.swift`
- Test: `Packages/MTPKit/Tests/PhoneDetectionTests/ArrivalFilterTests.swift`

**Interfaces:**
- Consumes: nothing. Callers pass `isFileTransfer` from Task 1.
- Produces:

```swift
public struct ArrivalFilter: Sendable {
    public static let wakeGrace: TimeInterval = 10       // spec: ~10 s after wake
    public static let reconnectGrace: TimeInterval = 5   // spec: ~5 s after the same phone left
    public init()
    /// Devices present when the watcher starts; never trigger, but their removal is remembered.
    public mutating func noteExisting(entryID: UInt64, key: String, isFileTransfer: Bool)
    /// Returns true if Tether should open for this arrival.
    public mutating func noteArrival(entryID: UInt64, key: String, isFileTransfer: Bool, at now: Date) -> Bool
    public mutating func noteRemoval(entryID: UInt64, at now: Date)
    public mutating func noteWake(at now: Date)
}
```

`key` is the USB serial number, or `"loc:<locationID>"` when there's no serial. `entryID` is the IORegistry entry ID.

- [ ] **Step 1: Write the failing tests.** Use `let t0 = Date(timeIntervalSinceReferenceDate: 0)` and offsets from it.

```swift
@Test func fileTransferArrivalOpens() {
    var f = ArrivalFilter()
    #expect(f.noteArrival(entryID: 1, key: "S", isFileTransfer: true, at: t0))
}
@Test func chargingArrivalDoesNotOpen() {
    var f = ArrivalFilter()
    #expect(!f.noteArrival(entryID: 1, key: "S", isFileTransfer: false, at: t0))
}
@Test func switchFromChargingToFileTransferOpens() {   // phone re-enumerates within 1 s, same serial
    var f = ArrivalFilter()
    _ = f.noteArrival(entryID: 1, key: "S", isFileTransfer: false, at: t0)
    f.noteRemoval(entryID: 1, at: t0 + 10)
    #expect(f.noteArrival(entryID: 2, key: "S", isFileTransfer: true, at: t0 + 11))
}
@Test func quickReplugOfFileTransferPhoneIsIgnored() {
    var f = ArrivalFilter()
    _ = f.noteArrival(entryID: 1, key: "S", isFileTransfer: true, at: t0)
    f.noteRemoval(entryID: 1, at: t0 + 30)
    #expect(!f.noteArrival(entryID: 2, key: "S", isFileTransfer: true, at: t0 + 34))
}
@Test func replugAfterGraceOpens() {
    var f = ArrivalFilter()
    _ = f.noteArrival(entryID: 1, key: "S", isFileTransfer: true, at: t0)
    f.noteRemoval(entryID: 1, at: t0 + 30)
    #expect(f.noteArrival(entryID: 2, key: "S", isFileTransfer: true, at: t0 + 36))
}
@Test func arrivalsRightAfterWakeAreIgnored() {
    var f = ArrivalFilter()
    f.noteWake(at: t0)
    #expect(!f.noteArrival(entryID: 1, key: "S", isFileTransfer: true, at: t0 + 9))
    #expect(f.noteArrival(entryID: 2, key: "T", isFileTransfer: true, at: t0 + 11))
}
@Test func existingDevicesAtStartAreIgnored() {
    var f = ArrivalFilter()
    f.noteExisting(entryID: 1, key: "S", isFileTransfer: true)
    f.noteRemoval(entryID: 1, at: t0)              // dock reconnect right after login
    #expect(!f.noteArrival(entryID: 2, key: "S", isFileTransfer: true, at: t0 + 2))
}
@Test func otherPhoneIsNotAffectedByReconnectGrace() {
    var f = ArrivalFilter()
    _ = f.noteArrival(entryID: 1, key: "S", isFileTransfer: true, at: t0)
    f.noteRemoval(entryID: 1, at: t0 + 30)
    #expect(f.noteArrival(entryID: 2, key: "T", isFileTransfer: true, at: t0 + 31))
}
@Test func duplicateNotificationForSameEntryOpensOnce() {
    var f = ArrivalFilter()
    #expect(f.noteArrival(entryID: 1, key: "S", isFileTransfer: true, at: t0))
    #expect(!f.noteArrival(entryID: 1, key: "S", isFileTransfer: true, at: t0 + 1))
}
```

- [ ] **Step 2: Run them and confirm they fail.** `swift test --filter ArrivalFilterTests`. Expected: compile failure, `cannot find 'ArrivalFilter'`.

- [ ] **Step 3: Implement `ArrivalFilter`.** Keep `present: [UInt64: (key: String, isFileTransfer: Bool)]`, `fileTransferLeft: [String: Date]` (recorded only when the departing entry was File transfer) and `lastWake: Date?`. An arrival opens only if all of these hold: it's File transfer, its entry ID isn't already in `present`, it isn't within `wakeGrace` of `lastWake`, and it isn't within `reconnectGrace` of `fileTransferLeft[key]`. Drop entries older than `reconnectGrace` from `fileTransferLeft` on each call.

- [ ] **Step 4: Run them and confirm they pass.** Expected: 9 tests pass.

- [ ] **Step 5: Commit** `feat(detection): ignore wakes, reconnects and duplicate arrivals`

---

### Task 3: `AutoOpenController` — register, unregister, repair after updates

**Files:**
- Create: `Packages/MTPKit/Sources/TetherCore/AutoOpen.swift`
- Modify: `Packages/MTPKit/Sources/TetherCore/AppSettings.swift`: add `SettingsKey.autoOpenRegisteredVersion = "autoOpenRegisteredVersion"`
- Test: `Packages/MTPKit/Tests/TetherCoreTests/AutoOpenTests.swift`

**Interfaces:**
- Produces:

```swift
public enum LoginItemStatus: Sendable { case notRegistered, enabled, requiresApproval, notFound }

@MainActor public protocol LoginItemService: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

@MainActor @Observable public final class AutoOpenController {
    public enum State: Equatable, Sendable { case off, on, needsApproval }
    public private(set) var state: State
    public private(set) var lastError: String?     // localizedDescription of the last failed register/unregister
    public init(service: any LoginItemService,
                defaults: UserDefaults = .standard,
                currentVersion: String,             // "\(CFBundleShortVersionString) (\(CFBundleVersion))"
                isHelperRunning: @escaping @MainActor () -> Bool,
                pollInterval: Duration = .milliseconds(250),
                pollTimeout: Duration = .seconds(5),
                settleDelay: Duration = .seconds(1))
    public var isOn: Bool { get }                   // state == .on
    public func refresh()                           // re-read service.status into state
    public func setEnabled(_ on: Bool) async
    public func repairIfNeeded() async
}
```

Status mapping: `.enabled` → `.on`, `.requiresApproval` → `.needsApproval`, anything else → `.off`.

- [ ] **Step 1: Write the failing tests.** Create `@MainActor final class FakeLoginItem: LoginItemService` with `var status`, `var calls: [String]` (`"register"` / `"unregister"`), and `var failNextRegister: Error?`. `register()` sets status to `.enabled`, `unregister()` sets it to `.notRegistered`. Pass `pollInterval: .zero, settleDelay: .zero` in every test, and use a fresh `UserDefaults(suiteName:)` per test as in `AppSettingsTests`.

```swift
@Test func offByDefault()                          // status .notRegistered → state == .off, calls == []
@Test func enableRegistersAndStoresVersion()       // setEnabled(true) → calls == ["register"], state == .on,
                                                   // defaults[autoOpenRegisteredVersion] == "1.1.0 (7)"
@Test func disableUnregistersAndClearsVersion()    // from on: setEnabled(false) → calls ends with "unregister",
                                                   // state == .off, stored version == nil
@Test func registerFailureReportsErrorAndStaysOff()// failNextRegister set → state == .off, lastError != nil
@Test func requiresApprovalMapsToNeedsApproval()   // status .requiresApproval → state == .needsApproval
@Test func refreshPicksUpExternalChange()          // on; fake.status = .notRegistered; refresh() → state == .off
@Test func repairReregistersAfterVersionChange()   // status .enabled, stored "1.0.1 (1)", current "1.1.0 (7)",
                                                   // helper running → calls == ["unregister", "register"],
                                                   // stored == "1.1.0 (7)", state == .on
@Test func repairReregistersWhenHelperNotRunning() // stored == current, isHelperRunning false → ["unregister", "register"]
@Test func repairDoesNothingWhenCurrentAndRunning()// stored == current, running → calls == []
@Test func repairDoesNothingWhenOff()              // status .notRegistered, stored differs → calls == []
@Test func reregisterWaitsForOldHelperToExit()     // isHelperRunning returns true for its first 3 calls after
                                                   // unregister, then false; record the call count when
                                                   // register() runs → register happens after the 4th check
```

- [ ] **Step 2: Run them and confirm they fail.** `cd Packages/MTPKit && swift test --filter AutoOpenTests`. Expected: compile failure, `cannot find 'AutoOpenController'`.

- [ ] **Step 3: Implement `AutoOpen.swift`.** Re-register works like this (from the spike):
  1. `unregister()`.
  2. Poll `isHelperRunning()` every `pollInterval` until it's false or `pollTimeout` passes.
  3. `try? await Task.sleep(for: settleDelay)`.
  4. `register()`, store `currentVersion`, `refresh()`.

  `repairIfNeeded` only acts when the status is `.enabled` and either the stored version differs or the helper isn't running. Failed calls set `lastError` and never throw out of the controller.

- [ ] **Step 4: Run them and confirm they pass.** Expected: 11 tests pass. Also run `swift test --filter LocalizationCatalogTests`, which should still pass (this task adds no strings).

- [ ] **Step 5: Commit** `feat(core): AutoOpenController registers the launcher and repairs it after updates`

---

### Task 4: `TetherLauncher` login item

**Files:**
- Create: `TetherLauncher/main.swift`, which wires everything together, runs `NSApplication` with `.prohibited` activation policy, and calls `dispatchMain()`/`app.run()`.
- Create: `TetherLauncher/USBArrivalWatcher.swift`, which handles IOKit device arrival and removal.
- Create: `TetherLauncher/TetherOpener.swift`, which opens the containing app.
- Modify: `project.yml`: add the `TetherLauncher` target and embed it in `Tether`.

**Interfaces:**
- Consumes: `FileTransferMatch.isFileTransfer`, `USBInterfaceInfo`, `ArrivalFilter` (Tasks 1–2).
- Produces: a bundle at `Tether.app/Contents/Library/LoginItems/TetherLauncher.app` with bundle ID `dev.tether.Tether.Launcher`, which Task 5 registers.

- [ ] **Step 1: Add the target to `project.yml`.**

```yaml
  TetherLauncher:
    type: application
    platform: macOS
    sources: [TetherLauncher]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.tether.Tether.Launcher
        PRODUCT_NAME: TetherLauncher
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_LSUIElement: YES
        SKIP_INSTALL: YES
    dependencies:
      - package: MTPKit
        product: PhoneDetection
```

  Then add this to the `Tether` target's `dependencies`:

```yaml
      - target: TetherLauncher
        embed: true
        copy:
          destination: wrapper
          subpath: Contents/Library/LoginItems
```

- [ ] **Step 2: Implement `USBArrivalWatcher`.**
  - Register `IOServiceAddMatchingNotification` for `kIOFirstMatchNotification` and `kIOTerminatedNotification` on `IOServiceMatching("IOUSBHostDevice")`, delivered on `.main`, following the pattern in `MTPHelper/USBWatcher.swift`.
  - On the first drain of the "added" iterator, call `filter.noteExisting` for each device. Don't open anything.
  - For each later arrival, read the interfaces 1.5 s after the notification. If no `IOUSBHostInterface` children exist yet, read again at 3 s. Then call `noteArrival`.
  - Read the interface fields with `IORegistryEntryCreateCFProperty`: `bInterfaceClass`, `bInterfaceSubClass`, `bInterfaceProtocol`, and the name from **`kUSBString`**. Walk the device's children recursively in `kIOServicePlane`.
  - The key comes from `kUSBSerialNumberString`, falling back to `"loc:\(locationID)"`. The entry ID comes from `IORegistryEntryGetRegistryEntryID`.
  - Observe `NSWorkspace.didWakeNotification` and call `filter.noteWake(at: Date())`.
  - Never open the device and never create a user client.

- [ ] **Step 3: Implement `TetherOpener.open()`.** Find the app with `Bundle.main.bundleURL` minus 4 path components (`TetherLauncher.app` → `LoginItems` → `Library` → `Contents` → `Tether.app`). Then call `NSWorkspace.shared.openApplication(at:configuration:)` with `configuration.activates = true`. If the URL doesn't end in `.app`, log with `os_log` and do nothing.

- [ ] **Step 4: Build and check the bundle.**

```bash
xcodegen generate && xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Debug -derivedDataPath DerivedData build | tail -3
APP=DerivedData/Build/Products/Debug/Tether.app
L=$APP/Contents/Library/LoginItems/TetherLauncher.app
test -d "$L" && echo embedded
otool -L "$L/Contents/MacOS/TetherLauncher" | grep -E "mtp|usb-1.0" || echo "no libmtp/libusb"
codesign --verify --deep --strict "$APP" && echo signed
```

  Expected: `** BUILD SUCCEEDED **`, no warnings, then `embedded`, `no libmtp/libusb`, `signed`.

- [ ] **Step 5: Commit** `feat(launcher): login item that opens Tether when a phone enters File transfer mode`

---

### Task 5: Wire it into the app — Settings toggle, launch repair, select the new phone

**Files:**
- Create: `Tether/LoginItem.swift`, containing `final class SMLoginItem: LoginItemService` that wraps `SMAppService.loginItem(identifier: "dev.tether.Tether.Launcher")` and maps `SMAppService.Status` to `LoginItemStatus`. Also add `static func isLauncherRunning() -> Bool`, which checks `!NSRunningApplication.runningApplications(withBundleIdentifier: "dev.tether.Tether.Launcher").isEmpty`.
- Modify: `Tether/TetherApp.swift`
  - Create `autoOpen: AutoOpenController?`. It's `nil` when `UseFakeDevices` is set. The version string is `"\(short) (\(build))"` from `Bundle.main.infoDictionary`.
  - Call `await autoOpen?.repairIfNeeded()` once at startup, in the window's `.task` next to `model.start()`.
  - Pass `autoOpen` to `SettingsView` and `ContentView`.
- Modify: `Tether/SettingsView.swift`. Only when `autoOpen != nil`, add:
  - `Toggle("Open Tether when a phone connects", isOn:)`. The binding gets `autoOpen.isOn` and sets it with `Task { await autoOpen.setEnabled($0) }`.
  - When `state == .needsApproval`: the text "Allow Tether in Login Items to finish turning this on." and the button "Open Login Items…", which calls `SMAppService.openSystemSettingsLoginItems()`.
  - When `lastError != nil`: show it as secondary text.
  - Call `autoOpen.refresh()` in `.onAppear`.
- Modify: `Tether/ContentView.swift`. When `autoOpen?.isOn == true` and a device ID shows up in `model.devices.devices` that wasn't in the previous value, remember it as `pendingDevice`. When that device has storages in `ensureSelection`, select its first storage, then clear `pendingDevice`. The existing behaviour stays as is when auto-open is off.
- Modify: `Tether/Localizable.xcstrings`, by running `scripts/sync-strings.sh`, then adding the Russian translations:
  - "Open Tether when a phone connects" → «Открывать Tether при подключении телефона»
  - "Allow Tether in Login Items to finish turning this on." → «Разрешите Tether в разделе «Объекты входа», чтобы включить эту функцию.»
  - "Open Login Items…" → «Открыть «Объекты входа»…»

**Interfaces:**
- Consumes: `AutoOpenController`, `LoginItemService`, `LoginItemStatus` (Task 3), and the launcher bundle ID (Task 4).

- [ ] **Step 1: Implement the files above.**
- [ ] **Step 2: Run the strings sync, translate, and check.** Run `scripts/sync-strings.sh`, add the `ru` values, then run `cd Packages/MTPKit && swift test --filter LocalizationCatalogTests`. Expected: pass.
- [ ] **Step 3: Run the full CI-equivalent check.**

```bash
cd Packages/MTPKit && xcodebuild test -scheme MTPKit-Package -destination 'platform=macOS' -derivedDataPath ../../DerivedData/pkg | tail -3 && cd ../..
xcodegen generate && xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Debug -derivedDataPath DerivedData build | tee build.log | tail -3
grep -E '\.(swift|m|c|h):[0-9]+:[0-9]+: warning:' build.log || echo "no warnings"
scripts/sync-strings.sh && git diff --exit-code -- '*.xcstrings' && echo "strings in sync"
```

  Expected: `** TEST SUCCEEDED **`, `** BUILD SUCCEEDED **`, `no warnings`, `strings in sync`.

- [ ] **Step 4: Run the UI tests (fake mode, so the toggle is hidden).** `xcodebuild test -project Tether.xcodeproj -scheme Tether -destination 'platform=macOS' -derivedDataPath DerivedData | tail -3`. Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 5: Commit** `feat(app): Settings toggle to open Tether when a phone connects`

---

### Task 6: Device checklist and end-to-end check on a real phone

**Files:**
- Modify: `docs/testing/device-checklist.md`. Add an `## Auto-open` section with the rows below.

- [ ] **Step 1: Add the checklist rows.**

```markdown
## Auto-open
- [ ] Settings → turn on "Open Tether when a phone connects": stays on; one system "background item" notice at most.
- [ ] Quit Tether, plug in a phone in "File transfer": Tether opens in front within 5 s with that phone selected.
- [ ] Plug in "Charging only": nothing opens. Switch to "File transfer": Tether opens.
- [ ] Locked phone already in File transfer: Tether opens on the "Unlock …" screen.
- [ ] Tether running with its window closed (⌘W) / minimized: replug → the window comes back in front.
- [ ] Quit Tether while the phone stays connected: it does not reopen within 1 minute.
- [ ] Phone connected before logging in: after login Tether does not open.
- [ ] Sleep the Mac with the phone connected, wake: Tether does not open.
- [ ] Plug in an iPhone or camera: Tether does not open.
- [ ] Install the next build over this one (or a Sparkle update), launch once, quit, replug: Tether still opens.
- [ ] Restart the Mac with auto-open on, then plug in: Tether opens.
- [ ] Turn the setting off: `launchctl print gui/$(id -u)/dev.tether.Tether.Launcher` reports no such service.
- [ ] Activity Monitor: TetherLauncher under ~15 MB memory and 0.0% CPU while idle.
```

- [ ] **Step 2: Run the rows you can do on this Mac** with a Release-like build (`scripts/build-release.sh`, installed to `/Applications`). Note the phone, Android version and build next to each row. For the update row, build twice with different `BUILD` numbers. Expected: every row passes. If the window doesn't come back after ⌘W, add an `NSApplicationDelegateAdaptor` whose `applicationShouldHandleReopen(_:hasVisibleWindows:)` calls `openWindow(id: "main")` when there are no visible windows, then re-run that row.
- [ ] **Step 3: Commit** `docs: device checklist for auto-open`
