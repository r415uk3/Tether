# Tether File Operations (Plan 2a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Tether a complete file manager for a phone:
- a Replace / Keep Both / Skip dialog when an upload's name already exists
- rename, delete and new folder
- a context menu, keyboard shortcuts and menu-bar commands
- a Settings window
- a file list whose selection can't point at the wrong files
- phones that keep their identity across unplug/replug, so Retry works

**Architecture:** This plan builds on Plan 1's layers. The work splits like this:
- **MTPKit:** gains a `ConflictResolution` upload policy, implemented in `Transfers.upload`. A replace never deletes the original before the new copy has fully arrived. It also gains stable device IDs: `LocalMTPService` maps the USB transport key to the phone's serial.
- **TetherCore:** gains pure, unit-tested UI logic: `UploadPlanner` (which clashes to ask about), `NameValidation`, `EntryFilter` and `AppSettings`.
- **App:** gains the AppKit and SwiftUI glue: an `NSTableView` that tracks selection and does inline rename and a context menu, an `NSAlert` conflict prompt, `Commands`, and a `Settings` scene.

**Tech Stack:** Swift 6 language mode, SwiftUI (`Commands`, `FocusedValues` with `@Entry`, `Settings`, `@AppStorage`), AppKit (`NSTableView`, `NSMenu`, `NSAlert`, `NSTextField` editing), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-01-tether-design.md` (§4 upload conflicts and other operations; §5 keyboard, settings and toolbar)
**Builds on:** `docs/superpowers/plans/2026-10-01-tether-core.md` (Plan 1, branch `feat/core`, PR #1) and the follow-ups in `docs/superpowers/notes/2026-10-01-plan1-followups.md`.

**Plan series:** Plan 2 is split into two plans:
- **2a (this plan):** file operations.
- **2b:**
  - icon view and thumbnails
  - Quick Look
  - Image Capture detection and the "Release" button
  - the full set of empty and error screens
  - English and Russian String Catalog
  - VoiceOver
  - Help → Copy Diagnostics
  - XCUITest
  - Liquid Glass polish

**Branching:** create `feat/file-ops` from `feat/core`. PR #1 is not merged yet, so this PR stacks on it.

## Global Constraints

- **Platform and language:** minimum macOS 15.0, Swift 6 language mode with strict concurrency, and no `@preconcurrency` imports. Use `Unchecked<T>` (MTPKit) for AppKit/XPC values that cross isolation.
- **Byte counts:** file sizes and byte counts are `UInt64`.
- **Root folder:** the MTP root folder ID is `FileEntry.rootID` (`0xFFFFFFFF`).
- **Localization:** user-facing strings use `String(localized:)` or `LocalizedStringKey`, so Plan 2b can extract them.
- **Replace (spec §4):** Replace means the new item is uploaded under a temporary name, then the existing item is deleted, then the new item is renamed. A failure or cancel before the delete leaves the original untouched.
- **Conflict dialog (spec §4):** the buttons are **Replace**, **Keep Both** and **Skip**, plus an "Apply to all" checkbox. Keep Both appends " 2", " 3" and so on, using `Transfers.uniqueName`.
- **Delete confirmation (spec §4):** delete asks for confirmation with "This can’t be undone." Deleting a folder deletes its contents.
- **New folder (spec §4):** creates "untitled folder" (made unique) and immediately enters rename mode.
- **Keyboard (spec §5):**

  | Shortcut | Action |
  |---|---|
  | ⌘↑ | Enclosing folder |
  | ↩ | Rename |
  | ⌘⌫ | Delete |
  | ⇧⌘N | New folder |
  | ⌘R | Refresh |

  Plan 2a also adds ⌘↓ (Open), ⌥⌘D (Download) and ⇧⌘. (show hidden files).
- **Settings (spec §5):**
  - default download folder (defaults to ~/Downloads)
  - default answer for name conflicts: Ask / Replace / Keep Both / Skip
  - show hidden files

  A hidden file is one whose name starts with ".".
- **Project file:** the Xcode project is generated from `project.yml`. New Swift files under `Tether/` are picked up automatically, so run `xcodegen generate` after adding them.

## Review Focus

1. **Two files with the same name dropped at once** (from different Mac folders) into a folder that has neither. The second must be treated as a clash and asked about, not left to fail later as `.nameConflict`. Pinned in Task 4, `duplicateNamesWithinOneDropAreConflicts`.
2. **A Replace that is cancelled or fails mid-upload** must leave the original exactly as it was. Pinned in Task 2, `cancelledReplaceKeepsOriginal`.
3. **Invalid renames:** renaming to a sibling's name, to an empty name, to a name containing "/", or to "." / ".." is rejected with a message, and nothing is sent to the phone. A case-only rename ("a.txt" → "A.txt") is allowed. Pinned in Task 4, `NameValidationTests`.
4. **Retry after replug:** a phone unplugged and replugged between a failure and the Retry gets a new USB transport key. Retry must still succeed. Pinned in Task 1, `retryAfterReplugUsesStableIdentity`.
5. **Hidden clashes:** hidden files (".nomedia", ".thumbnails") are hidden from the list by default, but they still count as name clashes when uploading. Pinned in Task 4, `hiddenEntriesAreFilteredButStillClash`.

---

## File Structure

```
Packages/MTPKit/Sources/MTPKit/
  ConflictResolution.swift        # NEW: upload policy enum (Task 2)
  Transfers+Upload.swift          # MODIFY: conflict policy, safe replace (Task 2)
  LocalMTPService.swift           # MODIFY: stable IDs (Task 1), conflict param (Task 3)
  FakeDeviceProvider.swift        # MODIFY: attach(_:as:) (Task 1)
  MTPService.swift                # MODIFY: upload(conflict:) + convenience (Task 3)
  XPC/XPCMessages.swift           # MODIFY: upload request carries conflict (Task 3)
  XPC/MTPXPCEndpoint.swift        # MODIFY (Task 3)
  XPC/XPCMTPService.swift         # MODIFY (Task 3)
Packages/MTPKit/Sources/TetherCore/
  TransferQueue.swift             # MODIFY: upload kind carries conflict (Task 3)
  AppModel.swift                  # MODIFY: pattern match (Task 3)
  UploadPlanner.swift             # NEW (Task 4)
  NameValidation.swift            # NEW (Task 4)
  EntryFilter.swift               # NEW (Task 4)
  AppSettings.swift               # NEW (Task 4)
MTPHelper/LibMTPDevice.swift      # MODIFY: serial-based ID (Task 1)
Tether/
  FileTableView.swift             # REWRITE: selection by ID, rename, context menu (Task 5)
  ConflictPrompt.swift            # NEW: NSAlert (Task 5)
  BrowserView.swift               # REWRITE: owns path, operations (Task 5), focused actions (Task 6)
  ContentView.swift               # MODIFY: path removed (Task 5), Transfers button (Task 6)
  BrowserCommands.swift           # NEW: menus + FocusedValues (Task 6)
  SettingsView.swift              # NEW (Task 6)
  TetherApp.swift                 # MODIFY: commands + Settings scene (Task 6)
```

Run every command from the repo root, `~/Tether`.

---

### Task 1: Stable device identity

**Files:**
- Modify: `Packages/MTPKit/Sources/MTPKit/LocalMTPService.swift`
- Modify: `Packages/MTPKit/Sources/MTPKit/FakeDeviceProvider.swift`
- Modify: `MTPHelper/LibMTPDevice.swift:10-15`
- Test: `Packages/MTPKit/Tests/MTPKitTests/StableIdentityTests.swift` (new), `Packages/MTPKit/Tests/TetherCoreTests/TransferQueueTests.swift` (add one test)

**Interfaces:**
- Consumes: `DeviceProvider`, `AttachedDevice`, `MTPDevice.info`, `LocalMTPService` (Plan 1).
- Produces:
  - **Public IDs:** `DeviceInfo.id` from `LocalMTPService` is now the opened device's own `info.id` (for libmtp, `"serial-<serial>"`). It falls back to the transport key when the device couldn't be opened, or when two attached devices report the same ID. Every `MTPService` method keeps taking that public ID.
  - **New test API:** `FakeDeviceProvider.attach(_ device: FakeDevice, as key: DeviceID)` attaches under an explicit transport key. The existing `attach(_:)` still uses `device.info.id` as the key.

**Why:** Plan 1 used the transport key `"<bus>-<devnum>"` as the device ID. An unplug/replug changes the devnum, so retries, selection and cached listings were orphaned.

- [ ] **Step 1: Write the failing tests**

`Packages/MTPKit/Tests/MTPKitTests/StableIdentityTests.swift`:

```swift
import Foundation
import Testing
@testable import MTPKit

@Suite struct StableIdentityTests {
    let provider = FakeDeviceProvider()

    @Test func reportsDeviceIdentityAndResolvesOperations() async throws {
        let device = FakeDevice(id: "serial-ABC")
        device.addFolder("DCIM")
        provider.attach(device, as: "14-4")
        let service = LocalMTPService(provider: provider)
        #expect(try await service.devices().map(\.id) == ["serial-ABC"])
        #expect(try await service.storages(deviceID: "serial-ABC").map(\.id) == [1])
        #expect(try await service.list(FolderRef(deviceID: "serial-ABC", storageID: 1)).map(\.name) == ["DCIM"])
    }

    @Test func replugUnderNewKeyKeepsIdentity() async throws {
        let device = FakeDevice(id: "serial-ABC")
        provider.attach(device, as: "14-4")
        let service = LocalMTPService(provider: provider)
        _ = try await service.devices()
        provider.detach("14-4")
        await service.rescan()
        #expect(try await service.devices().isEmpty)
        provider.attach(device, as: "14-7")
        await service.rescan()
        #expect(try await service.devices().map(\.id) == ["serial-ABC"])
        #expect(try await service.list(FolderRef(deviceID: "serial-ABC", storageID: 1)).isEmpty)
    }

    @Test func duplicateIdentitiesFallBackToTransportKey() async throws {
        provider.attach(FakeDevice(id: "serial-SAME"), as: "k1")
        provider.attach(FakeDevice(id: "serial-SAME"), as: "k2")
        let service = LocalMTPService(provider: provider)
        #expect(Set(try await service.devices().map(\.id)) == ["serial-SAME", "k2"])
    }

    @Test func unopenableDeviceKeepsTransportKey() async throws {
        provider.attachUnavailable(AttachedDevice(id: "14-9", manufacturer: "Samsung", model: "S25"), error: .deviceLocked)
        let service = LocalMTPService(provider: provider)
        #expect(try await service.devices().map(\.id) == ["14-9"])
        await #expect(throws: MTPError.deviceLocked) { try await service.storages(deviceID: "14-9") }
    }
}
```

Add to `Packages/MTPKit/Tests/TetherCoreTests/TransferQueueTests.swift`, inside `TransferQueueTests`:

```swift
    @Test func retryAfterReplugUsesStableIdentity() async throws {
        let provider = FakeDeviceProvider()
        let phone = FakeDevice(id: "serial-ABC")
        provider.attach(phone, as: "14-4")
        let service = LocalMTPService(provider: provider)
        #expect(try await service.devices().map(\.id) == ["serial-ABC"])
        let file = phone.addFile("a.txt", data: Data("x".utf8))
        let queue = TransferQueue(service: service)
        phone.inject(.fail(.deviceDisconnected))
        let id = queue.enqueueDownload(file, deviceID: "serial-ABC", into: try makeTempDirectory())
        try await eventually { queue.jobs[0].state == .failed(.deviceDisconnected) }
        provider.detach("14-4")
        await service.rescan()
        provider.attach(phone, as: "14-7")
        await service.rescan()
        queue.retry(id)
        try await eventually { if case .finished = queue.jobs[0].state { true } else { false } }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/MTPKit --filter "StableIdentityTests|retryAfterReplug"`
Expected: compile error `extra argument 'as' in call`.

- [ ] **Step 3: Add `attach(_:as:)` to `FakeDeviceProvider`**

In `Packages/MTPKit/Sources/MTPKit/FakeDeviceProvider.swift`:

1. Replace the `Slot.attached` computed property with a function that takes the key:

```swift
        func attached(as key: DeviceID) -> AttachedDevice {
            switch self {
            case .device(let d): AttachedDevice(id: key, manufacturer: d.info.manufacturer, model: d.info.model)
            case .unavailable(let a, _): a
            }
        }
```

2. Replace `attach(_:)` with these two methods:

```swift
    /// Attaches (or replaces) a working device under its own ID as transport key.
    public func attach(_ device: FakeDevice) { attach(device, as: device.info.id) }

    /// Attaches (or replaces) a working device under an explicit USB transport key (simulates a replug).
    public func attach(_ device: FakeDevice, as key: DeviceID) { lock.withLock { slots[key] = .device(device) } }
```

3. Replace the body of `attachedDevices()`:

```swift
    public func attachedDevices() -> [AttachedDevice] {
        lock.withLock { slots.map { key, slot in slot.attached(as: key) }.sorted { $0.id < $1.id } }
    }
```

- [ ] **Step 4: Map transport keys to public IDs in `LocalMTPService`**

In `Packages/MTPKit/Sources/MTPKit/LocalMTPService.swift`:

1. Add a stored property after `generations`:

```swift
    /// Transport key -> the device's own identity (e.g. "serial-…"), stable across unplug/replug.
    /// Internal maps stay keyed by transport key; `DeviceInfo.id` and all public calls use the identity.
    private var publicIDs: [DeviceID: DeviceID] = [:]
```

2. In `performScan()`, inside the first loop (devices no longer attached), add `publicIDs[id] = nil` after `infos[id] = nil`.

3. In `performScan()`, replace the `.success` branch:

```swift
            case .success(let opened):
                guard current else { opened.close(); continue }
                let identity = opened.info.id
                let taken = publicIDs.contains { $0.key != device.id && $0.value == identity }
                let publicID = taken ? device.id : identity
                publicIDs[device.id] = publicID
                workers[device.id] = DeviceWorker(device: opened, name: device.model)
                infos[device.id] = DeviceInfo(id: publicID, manufacturer: opened.info.manufacturer,
                                              model: opened.info.model, state: opened.info.state)
```

4. In `restart()`, add `publicIDs.removeAll()` after `infos.removeAll()`.

5. Replace `worker(_ id: DeviceID) throws -> DeviceWorker`:

```swift
    private func worker(_ id: DeviceID) throws -> DeviceWorker {
        let key = publicIDs.first { $0.value == id }?.key ?? id
        if let worker = workers[key] { return worker }
        if case .unavailable(let error)? = infos[key]?.state { throw error }
        throw MTPError.deviceDisconnected
    }
```

`sortedDevices()` already sorts `infos.values` by `id`, which is now the public ID. Leave it unchanged.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path Packages/MTPKit`
Expected: all tests pass, including the 4 `StableIdentityTests` and `retryAfterReplugUsesStableIdentity`.

- [ ] **Step 6: Use the serial number in `LibMTPDevice`**

In `MTPHelper/LibMTPDevice.swift`, replace the `info = …` line in `init(handle:attached:)`:

```swift
        let serial = Self.take(LIBMTP_Get_Serialnumber(handle))
        info = DeviceInfo(id: serial.map { "serial-\($0)" } ?? attached.id,
                          manufacturer: manufacturer, model: model, state: .ready)
```

(`take` already frees the string and maps an empty string to nil.)

- [ ] **Step 7: Build the app**

Run: `xcodegen generate && xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Debug -derivedDataPath DerivedData build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
git add -A Packages/MTPKit MTPHelper
git commit -m "feat: stable device identity across unplug/replug (serial-based IDs)"
```

---

### Task 2: Upload conflict policy with safe Replace

**Files:**
- Create: `Packages/MTPKit/Sources/MTPKit/ConflictResolution.swift`
- Modify: `Packages/MTPKit/Sources/MTPKit/Transfers+Upload.swift`
- Test: `Packages/MTPKit/Tests/MTPKitTests/ConflictUploadTests.swift` (new)

**Interfaces:**
- Consumes: `Transfers.upload`, `Transfers.uniqueName(for:isTaken:)`, `LocalItem` (Plan 1), and `FakeDevice` (`addFile`, `addFolder`, `children(of:)`, `data(of:)`).
- Produces:
  - `public enum ConflictResolution: String, Codable, Sendable, CaseIterable { case fail, keepBoth, replace }`
  - `Transfers.upload(_:to:storageID:parentID:conflict:progress:)`. `conflict` defaults to `.fail`, so existing call sites compile unchanged.

**Rules:**
- **No clash:** the policy is ignored.
- **`.fail`:** throws `.nameConflict(name)`, as Plan 1 does.
- **`.keepBoth`:** uploads under `uniqueName(for: name)`, made unique against the folder's current names.
- **`.replace`:**
  1. Upload under a unique temporary name, `"<name>.tether-upload"`.
  2. On success, delete every existing item named `name`, then rename the new item to `name`.
  3. If deleting an old item fails, delete the new copy and throw. The user then still has the original.
  4. If the final rename fails, throw a message that names the temporary name.
- **Cleanup:** cancel and failure cleanup apply to the temporary or Keep Both name, exactly as they do for a normal upload.

- [ ] **Step 1: Write the failing tests**

`Packages/MTPKit/Tests/MTPKitTests/ConflictUploadTests.swift`:

```swift
import Foundation
import Testing
@testable import MTPKit

@Suite struct ConflictUploadTests {
    let root = FileEntry.rootID

    private func makeFile(_ name: String, _ text: String) throws -> URL {
        let url = try makeTempDirectory().appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func failPolicyStillRejects() throws {
        let device = FakeDevice()
        device.addFile("photo.jpg", data: Data("old".utf8))
        #expect(throws: MTPError.nameConflict("photo.jpg")) {
            try Transfers.upload(try makeFile("photo.jpg", "new"), to: device, storageID: 1, parentID: root,
                                 conflict: .fail) { _, _ in true }
        }
    }

    @Test func policyIsIgnoredWithoutAClash() throws {
        let device = FakeDevice()
        let a = try Transfers.upload(try makeFile("a.txt", "a"), to: device, storageID: 1, parentID: root,
                                     conflict: .replace) { _, _ in true }
        let b = try Transfers.upload(try makeFile("b.txt", "b"), to: device, storageID: 1, parentID: root,
                                     conflict: .keepBoth) { _, _ in true }
        #expect([a.name, b.name] == ["a.txt", "b.txt"])
        #expect(device.children(of: root).map(\.name) == ["a.txt", "b.txt"])
    }

    @Test func keepBothUploadsUnderNextFreeName() throws {
        let device = FakeDevice()
        device.addFile("photo.jpg", data: Data("old".utf8))
        device.addFile("photo 2.jpg", data: Data("older".utf8))
        let entry = try Transfers.upload(try makeFile("photo.jpg", "new"), to: device, storageID: 1, parentID: root,
                                         conflict: .keepBoth) { _, _ in true }
        #expect(entry.name == "photo 3.jpg")
        #expect(device.children(of: root).map(\.name).sorted() == ["photo 2.jpg", "photo 3.jpg", "photo.jpg"])
        #expect(device.data(of: entry.objectID) == Data("new".utf8))
    }

    @Test func replaceLeavesOneItemWithNewContents() throws {
        let device = FakeDevice()
        device.addFile("photo.jpg", data: Data("old".utf8))
        let entry = try Transfers.upload(try makeFile("photo.jpg", "new"), to: device, storageID: 1, parentID: root,
                                         conflict: .replace) { _, _ in true }
        let children = device.children(of: root)
        #expect(children.map(\.name) == ["photo.jpg"])
        #expect(entry.name == "photo.jpg")
        #expect(entry.objectID == children[0].objectID)
        #expect(device.data(of: children[0].objectID) == Data("new".utf8))
    }

    @Test func cancelledReplaceKeepsOriginal() throws {
        let device = FakeDevice(chunkSize: 4)
        let original = device.addFile("photo.jpg", data: Data("old".utf8))
        let url = try makeFile("photo.jpg", String(repeating: "n", count: 40))
        #expect(throws: MTPError.cancelled) {
            try Transfers.upload(url, to: device, storageID: 1, parentID: root, conflict: .replace) { done, _ in done < 8 }
        }
        #expect(device.children(of: root).map(\.objectID) == [original.objectID])
        #expect(device.data(of: original.objectID) == Data("old".utf8))
    }

    @Test func replaceFolderSwapsWholeTree() throws {
        let device = FakeDevice()
        let oldAlbum = device.addFolder("Album")
        device.addFile("old.jpg", data: Data(count: 3), in: oldAlbum.objectID)
        let dir = try makeTempDirectory()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Album"), withIntermediateDirectories: true)
        try Data(count: 5).write(to: dir.appendingPathComponent("Album/new.jpg"))
        let album = try Transfers.upload(dir.appendingPathComponent("Album"), to: device, storageID: 1, parentID: root,
                                         conflict: .replace) { _, _ in true }
        #expect(device.children(of: root).map(\.name) == ["Album"])
        #expect(device.children(of: album.objectID).map(\.name) == ["new.jpg"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/MTPKit --filter ConflictUploadTests`
Expected: compile error `cannot find 'ConflictResolution'` / `extra argument 'conflict'`.

- [ ] **Step 3: Create `ConflictResolution.swift`**

```swift
import Foundation

/// What an upload does when its destination folder already has an item with the same name.
public enum ConflictResolution: String, Codable, Sendable, CaseIterable {
    /// Refuse with `.nameConflict`. The app asks the user first, so this means the folder changed meanwhile.
    case fail
    /// Keep the existing item; upload as "name 2", "name 3", …
    case keepBoth
    /// Upload under a temporary name, then delete the existing item and rename the new one.
    /// The original is untouched until the new copy has fully arrived.
    case replace
}
```

- [ ] **Step 4: Implement the policy in `Transfers+Upload.swift`**

Replace the whole `upload(_:to:storageID:parentID:progress:)` function with this version, and add the two helpers below it:

```swift
    /// Uploads a file or folder into `parentID`. Checks space and name clashes before sending anything;
    /// `conflict` decides what a clash means (see `ConflictResolution`).
    public static func upload(_ source: URL, to device: any MTPDevice, storageID: UInt32, parentID: UInt32,
                              conflict: ConflictResolution = .fail, progress: ProgressHandler) throws -> FileEntry {
        let scanned = try LocalItem.scan(source)
        let total = scanned.reduce(UInt64(0)) { $0 + $1.size }

        guard let storage = try device.storages().first(where: { $0.id == storageID }) else { throw MTPError.notFound }
        guard storage.freeSpace >= total else {
            throw MTPError.storageFull(needed: total, available: storage.freeSpace)
        }
        let name = source.lastPathComponent
        let existing = try device.listFolder(storageID: storageID, folderID: parentID)
        let clashing = existing.filter { $0.name == name }
        let uploadName = try destinationName(for: name, clashing: clashing, existing: existing, conflict: conflict)
        let items = uploadName == name ? scanned : scanned.map { $0.renamingRoot(to: uploadName) }

        var createdRoot: FileEntry?
        var folderIDs: [[String]: UInt32] = [[]: parentID]
        var sent: UInt64 = 0
        do {
            for item in items {
                guard let parent = folderIDs[Array(item.components.dropLast())] else {
                    throw MTPError.underlying(code: -3, message: "Unexpected path while uploading \(name)")
                }
                let itemName = item.components.last!
                let created: FileEntry
                if item.isDirectory {
                    created = try device.createFolder(name: itemName, storageID: storageID, parentID: parent)
                    folderIDs[item.components] = created.objectID
                    guard progress(sent, total) else { throw MTPError.cancelled }
                } else {
                    let base = sent
                    created = try device.upload(from: item.url, name: itemName, size: item.size,
                                                storageID: storageID, parentID: parent) { done, _ in
                        progress(base + done, total)
                    }
                    sent += item.size
                }
                if createdRoot == nil { createdRoot = created }
            }
        } catch {
            if let createdRoot {
                try? device.delete(objectID: createdRoot.objectID)
            } else {
                removeIncomplete(named: uploadName, in: parentID, storageID: storageID,
                                 keeping: Set(existing.map(\.objectID)), on: device)
            }
            throw MTPError.from(error)
        }

        if conflict == .replace, !clashing.isEmpty {
            return try swapIn(createdRoot!, replacing: clashing, finalName: name, on: device)
        }
        return createdRoot!
    }

    /// The name the new item is uploaded under, given the folder's current contents.
    private static func destinationName(for name: String, clashing: [FileEntry], existing: [FileEntry],
                                        conflict: ConflictResolution) throws -> String {
        guard !clashing.isEmpty else { return name }
        let taken = Set(existing.map(\.name))
        switch conflict {
        case .fail: throw MTPError.nameConflict(name)
        case .keepBoth: return uniqueName(for: name) { taken.contains($0) }
        case .replace: return uniqueName(for: name + ".tether-upload") { taken.contains($0) }
        }
    }

    /// Final step of a Replace: the new item is complete under a temporary name.
    /// Delete the old item(s), then give the new one the original name.
    private static func swapIn(_ uploaded: FileEntry, replacing old: [FileEntry], finalName: String,
                               on device: any MTPDevice) throws -> FileEntry {
        do {
            for entry in old { try device.delete(objectID: entry.objectID) }
        } catch {
            // The original is (at least partly) still there: drop the new copy instead of leaving both.
            try? device.delete(objectID: uploaded.objectID)
            throw MTPError.from(error)
        }
        do {
            try device.rename(objectID: uploaded.objectID, to: finalName)
        } catch {
            let reason = MTPError.from(error).localizedDescription
            throw MTPError.underlying(code: -4, message: String(
                localized: "The new “\(finalName)” was copied as “\(uploaded.name)” but couldn’t be renamed. \(reason)"))
        }
        var renamed = uploaded
        renamed.name = finalName
        return renamed
    }
```

In `struct LocalItem`, add this method after the stored properties:

```swift
    /// The same item uploaded under a different top-level name (Keep Both / Replace's temporary name).
    func renamingRoot(to name: String) -> LocalItem {
        LocalItem(components: [name] + components.dropFirst(), url: url, isDirectory: isDirectory, size: size)
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path Packages/MTPKit --filter "ConflictUploadTests|UploadTests"`
Expected: 6 `ConflictUploadTests` pass, and every existing `UploadTests` case still passes.

- [ ] **Step 6: Commit**

```bash
git add -A Packages/MTPKit
git commit -m "feat(MTPKit): upload conflict policy (keep both, safe replace)"
```

---

### Task 3: Plumb the conflict policy through service, XPC and queue

**Files:**
- Modify: `Packages/MTPKit/Sources/MTPKit/MTPService.swift`
- Modify: `Packages/MTPKit/Sources/MTPKit/LocalMTPService.swift` (`upload`)
- Modify: `Packages/MTPKit/Sources/MTPKit/XPC/XPCMessages.swift`, `XPC/MTPXPCEndpoint.swift`, `XPC/XPCMTPService.swift`
- Modify: `Packages/MTPKit/Sources/TetherCore/TransferQueue.swift`, `Packages/MTPKit/Sources/TetherCore/AppModel.swift`
- Modify (tests): `Packages/MTPKit/Tests/MTPKitTests/XPCTests.swift`, `Packages/MTPKit/Tests/TetherCoreTests/DeviceStoreTests.swift` (`FlakyService`), `Packages/MTPKit/Tests/TetherCoreTests/TransferQueueTests.swift`

**Interfaces:**
- Consumes: `ConflictResolution` and `Transfers.upload(…conflict:…)` (Task 2).
- Produces:
  - `MTPService.upload(jobID: UUID, fileURL: URL, to folder: FolderRef, conflict: ConflictResolution) async throws -> FileEntry`. This is the protocol requirement.
  - `extension MTPService { func upload(jobID:fileURL:to:) }`, a convenience that uses `.fail`.
  - `XPCRequest.upload(jobID:fileURL:folder:conflict:)`.
  - `TransferQueue.Kind.upload(URL, folder: FolderRef, conflict: ConflictResolution)`.
  - `TransferQueue.enqueueUpload(_ url: URL, to folder: FolderRef, conflict: ConflictResolution = .fail) -> UUID`. It is `@discardableResult`.

- [ ] **Step 1: Write the failing tests**

In `Packages/MTPKit/Tests/MTPKitTests/XPCTests.swift`:

1. Change the codec test's request to include a policy:

```swift
        let request = XPCRequest.upload(jobID: UUID(), fileURL: URL(fileURLWithPath: "/tmp/a b.txt"),
                                        folder: FolderRef(deviceID: "d", storageID: 2, folderID: 9), conflict: .keepBoth)
```

2. Add inside `XPCTests`:

```swift
    @Test func uploadPolicyCrossesXPC() async throws {
        device.addFile("a.txt", data: Data("old".utf8))
        let (client, host) = makeClient()
        _ = try await client.devices()
        let file = try makeTempDirectory().appendingPathComponent("a.txt")
        try Data("new".utf8).write(to: file)
        let entry = try await client.upload(jobID: UUID(), fileURL: file, to: FolderRef(deviceID: "p1", storageID: 1),
                                            conflict: .keepBoth)
        #expect(entry.name == "a 2.txt")
        withExtendedLifetime(host) {}
    }
```

In `Packages/MTPKit/Tests/TetherCoreTests/TransferQueueTests.swift`, add inside `TransferQueueTests`:

```swift
    @Test func uploadCarriesConflictPolicy() async throws {
        device.addFile("up.txt", data: Data("old".utf8))
        let (queue, _) = try await makeQueue()
        let file = try makeTempDirectory().appendingPathComponent("up.txt")
        try Data("new".utf8).write(to: file)
        queue.enqueueUpload(file, to: FolderRef(deviceID: "p1", storageID: 1), conflict: .replace)
        try await eventually { if case .finished = queue.jobs[0].state { true } else { false } }
        let children = device.children(of: FileEntry.rootID)
        #expect(children.map(\.name) == ["up.txt"])
        #expect(device.data(of: children[0].objectID) == Data("new".utf8))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/MTPKit --filter "XPCTests|TransferQueueTests"`
Expected: compile errors: `extra argument 'conflict'`.

- [ ] **Step 3: Change the protocol and add the convenience**

In `MTPService.swift`, replace the `upload` requirement:

```swift
    func upload(jobID: UUID, fileURL: URL, to folder: FolderRef, conflict: ConflictResolution) async throws -> FileEntry
```

At the end of `MTPService.swift`, add:

```swift
public extension MTPService {
    /// Upload that refuses name clashes (`.fail`).
    func upload(jobID: UUID, fileURL: URL, to folder: FolderRef) async throws -> FileEntry {
        try await upload(jobID: jobID, fileURL: fileURL, to: folder, conflict: .fail)
    }
}
```

- [ ] **Step 4: Update `LocalMTPService.upload`**

```swift
    public func upload(jobID: UUID, fileURL: URL, to folder: FolderRef,
                       conflict: ConflictResolution) async throws -> FileEntry {
        let reporter = ProgressReporter(jobID: jobID, registry: cancellations, handler: eventHandler)
        defer { cancellations.clear(jobID) }
        return try await worker(folder.deviceID, scanning: true).perform(.transfer) { device in
            try reporter.checkCancelled()
            return try Transfers.upload(fileURL, to: device, storageID: folder.storageID, parentID: folder.folderID,
                                        conflict: conflict) {
                reporter.report(done: $0, total: $1)
            }
        }
    }
```

- [ ] **Step 5: Update the XPC layer**

`XPCMessages.swift`: change the request case:

```swift
    case upload(jobID: UUID, fileURL: URL, folder: FolderRef, conflict: ConflictResolution)
```

`MTPXPCEndpoint.swift`: change the `handle` case:

```swift
        case .upload(let jobID, let fileURL, let folder, let conflict):
            return .entry(try await service.upload(jobID: jobID, fileURL: fileURL, to: folder, conflict: conflict))
```

`XPCMTPService.swift`: replace `upload`:

```swift
    public func upload(jobID: UUID, fileURL: URL, to folder: FolderRef,
                       conflict: ConflictResolution) async throws -> FileEntry {
        let request = XPCRequest.upload(jobID: jobID, fileURL: fileURL, folder: folder, conflict: conflict)
        guard case .entry(let entry) = try await send(request) else { throw MTPError.unexpectedResponse }
        return entry
    }
```

- [ ] **Step 6: Update `TransferQueue` and `AppModel`**

In `TransferQueue.swift`:

1. Change the kind:

```swift
        case upload(URL, folder: FolderRef, conflict: ConflictResolution)
```

2. In `Job.name`, change the pattern to `case .upload(let url, _, _): url.lastPathComponent`. In `Job.deviceID`, change it to `case .upload(_, let folder, _): folder.deviceID`.

3. Replace `enqueueUpload`:

```swift
    @discardableResult
    public func enqueueUpload(_ url: URL, to folder: FolderRef, conflict: ConflictResolution = .fail) -> UUID {
        enqueue(.upload(url, folder: folder, conflict: conflict), completion: nil)
    }
```

4. In `run(_:)`, replace the upload case:

```swift
            case .upload(let url, let folder, let conflict):
                _ = try await service.upload(jobID: job.attempt, fileURL: url, to: folder, conflict: conflict)
                result = .success(nil)
```

In `AppModel.swift`, change the pattern to `guard case .upload(_, let folder, _) = job.kind, let store else { return }`.

- [ ] **Step 7: Update the `FlakyService` test double**

In `Packages/MTPKit/Tests/TetherCoreTests/DeviceStoreTests.swift`, replace its `upload` method:

```swift
    func upload(jobID: UUID, fileURL: URL, to folder: FolderRef, conflict: ConflictResolution) async throws -> FileEntry {
        try await base.upload(jobID: jobID, fileURL: fileURL, to: folder, conflict: conflict)
    }
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `swift test --package-path Packages/MTPKit`
Expected: all tests pass, including `uploadPolicyCrossesXPC` and `uploadCarriesConflictPolicy`.

- [ ] **Step 9: Build the app** (BrowserView calls `enqueueUpload(_:to:)`, which still compiles because of the default)

Run: `xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Debug -derivedDataPath DerivedData build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 10: Commit**

```bash
git add -A Packages/MTPKit
git commit -m "feat: carry upload conflict policy through service, XPC and transfer queue"
```

---

### Task 4: UI logic: upload planning, name validation, hidden files, settings

**Files:**
- Create: `Packages/MTPKit/Sources/TetherCore/UploadPlanner.swift`
- Create: `Packages/MTPKit/Sources/TetherCore/NameValidation.swift`
- Create: `Packages/MTPKit/Sources/TetherCore/EntryFilter.swift`
- Create: `Packages/MTPKit/Sources/TetherCore/AppSettings.swift`
- Test: `Packages/MTPKit/Tests/TetherCoreTests/UploadPlannerTests.swift`, `NameValidationTests.swift`, `EntryFilterTests.swift`, `AppSettingsTests.swift`

**Interfaces:**
- Consumes: `ConflictResolution` (Task 2), `Transfers.uniqueName(for:isTaken:)`, `FileEntry` (MTPKit).
- Produces (all `public`):
  - `enum ConflictChoice: Sendable, Equatable { case replace, keepBoth, skip }`
  - `struct ConflictQuestion: Sendable, Equatable { let name: String; let remaining: Int }`. `remaining` is the number of clashes left after this one.
  - `struct ConflictAnswer: Sendable, Equatable { let choice: ConflictChoice; let applyToAll: Bool; init(choice:applyToAll:) }`
  - `struct PlannedUpload: Sendable, Equatable { let url: URL; let conflict: ConflictResolution }`
  - `@MainActor enum UploadPlanner { static func plan(_ urls: [URL], existingNames: Set<String>, defaultChoice: ConflictChoice?, ask: (ConflictQuestion) async -> ConflictAnswer) async -> [PlannedUpload] }`
  - `enum NameProblem: Error, Equatable, Sendable { case empty, invalidCharacters, taken(String) }`, with `var message: String`
  - `enum RenameOutcome: Equatable, Sendable { case unchanged, valid(String), invalid(NameProblem) }`
  - `enum NameValidation { static func validate(_ proposed: String, current: String, siblings: [FileEntry]) -> RenameOutcome; static func newFolderName(siblings: [FileEntry]) -> String }`
  - `enum EntryFilter { static func visible(_ entries: [FileEntry], showHidden: Bool) -> [FileEntry] }`
  - `enum SettingsKey { static let downloadFolderPath, conflictDefault, showHiddenFiles }` (String keys)
  - `enum ConflictDefault: String, CaseIterable, Sendable { case ask, replace, keepBoth, skip }`, with `var choice: ConflictChoice?` and `var title: String`
  - `enum AppSettings { static var defaultDownloadFolder: URL; static func downloadFolder(in: UserDefaults = .standard) -> URL; static func conflictDefault(in: UserDefaults = .standard) -> ConflictDefault }`

**Rules for `UploadPlanner.plan`:**
- **What counts as a clash:** a URL clashes if its `lastPathComponent` is already in `existingNames`, or if an earlier URL in the same drop has that name.
- **Results:**
  - non-clashing → `.fail`
  - clashing + Replace → `.replace`
  - clashing + Keep Both → `.keepBoth`
  - clashing + Skip → left out of the result
- **Asking:** `defaultChoice` (from Settings) answers every clash without asking. Otherwise `ask` runs once per clash. An answer with `applyToAll` is reused for every later clash.
- **Order:** the input order is preserved.

- [ ] **Step 1: Write the failing tests**

`Packages/MTPKit/Tests/TetherCoreTests/UploadPlannerTests.swift`:

```swift
import Foundation
import Testing
import MTPKit
@testable import TetherCore

@MainActor
@Suite struct UploadPlannerTests {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func noClashesNeverAsks() async {
        var asked = 0
        let plan = await UploadPlanner.plan([url("/m/a.txt"), url("/m/b.txt")], existingNames: ["c.txt"],
                                            defaultChoice: nil) { _ in asked += 1; return .init(choice: .skip, applyToAll: false) }
        #expect(asked == 0)
        #expect(plan == [.init(url: url("/m/a.txt"), conflict: .fail), .init(url: url("/m/b.txt"), conflict: .fail)])
    }

    @Test func asksPerClashAndMapsChoices() async {
        var questions: [ConflictQuestion] = []
        var answers: [ConflictChoice] = [.replace, .skip]
        let plan = await UploadPlanner.plan([url("/m/a"), url("/m/b"), url("/m/c")], existingNames: ["a", "b"],
                                            defaultChoice: nil) { q in
            questions.append(q)
            return .init(choice: answers.removeFirst(), applyToAll: false)
        }
        #expect(questions == [.init(name: "a", remaining: 1), .init(name: "b", remaining: 0)])
        #expect(plan == [.init(url: url("/m/a"), conflict: .replace), .init(url: url("/m/c"), conflict: .fail)])
    }

    @Test func applyToAllReusesAnswer() async {
        var asked = 0
        let plan = await UploadPlanner.plan([url("/m/a"), url("/m/b")], existingNames: ["a", "b"],
                                            defaultChoice: nil) { _ in
            asked += 1
            return .init(choice: .keepBoth, applyToAll: true)
        }
        #expect(asked == 1)
        #expect(plan.map(\.conflict) == [.keepBoth, .keepBoth])
    }

    @Test func defaultChoiceAnswersWithoutAsking() async {
        var asked = 0
        let plan = await UploadPlanner.plan([url("/m/a"), url("/m/new")], existingNames: ["a"],
                                            defaultChoice: .skip) { _ in asked += 1; return .init(choice: .replace, applyToAll: false) }
        #expect(asked == 0)
        #expect(plan == [.init(url: url("/m/new"), conflict: .fail)])
    }

    @Test func duplicateNamesWithinOneDropAreConflicts() async {
        var questions: [ConflictQuestion] = []
        let plan = await UploadPlanner.plan([url("/x/a.txt"), url("/y/a.txt")], existingNames: [],
                                            defaultChoice: nil) { q in
            questions.append(q)
            return .init(choice: .keepBoth, applyToAll: false)
        }
        #expect(questions == [.init(name: "a.txt", remaining: 0)])
        #expect(plan == [.init(url: url("/x/a.txt"), conflict: .fail), .init(url: url("/y/a.txt"), conflict: .keepBoth)])
    }
}
```

`Packages/MTPKit/Tests/TetherCoreTests/NameValidationTests.swift`:

```swift
import Foundation
import Testing
import MTPKit
@testable import TetherCore

@Suite struct NameValidationTests {
    private func entry(_ name: String, _ id: UInt32) -> FileEntry {
        FileEntry(objectID: id, parentID: FileEntry.rootID, storageID: 1, name: name, size: 0, modified: nil, isFolder: false)
    }
    private var siblings: [FileEntry] { [entry("a.txt", 1), entry("b.txt", 2)] }

    @Test func acceptsANewName() {
        #expect(NameValidation.validate("  c.txt \n", current: "a.txt", siblings: siblings) == .valid("c.txt"))
    }

    @Test func sameNameIsUnchanged() {
        #expect(NameValidation.validate("a.txt", current: "a.txt", siblings: siblings) == .unchanged)
    }

    @Test func caseOnlyRenameIsAllowed() {
        #expect(NameValidation.validate("A.txt", current: "a.txt", siblings: siblings) == .valid("A.txt"))
    }

    @Test func rejectsTakenEmptyAndInvalidNames() {
        #expect(NameValidation.validate("b.txt", current: "a.txt", siblings: siblings) == .invalid(.taken("b.txt")))
        #expect(NameValidation.validate("   ", current: "a.txt", siblings: siblings) == .invalid(.empty))
        #expect(NameValidation.validate("x/y", current: "a.txt", siblings: siblings) == .invalid(.invalidCharacters))
        #expect(NameValidation.validate("..", current: "a.txt", siblings: siblings) == .invalid(.invalidCharacters))
        #expect(NameValidation.validate(".", current: "a.txt", siblings: siblings) == .invalid(.invalidCharacters))
    }

    @Test func problemsHaveMessages() {
        for problem in [NameProblem.empty, .invalidCharacters, .taken("b.txt")] { #expect(!problem.message.isEmpty) }
        #expect(NameProblem.taken("b.txt").message.contains("b.txt"))
    }

    @Test func newFolderNameIsUnique() {
        let base = String(localized: "untitled folder")
        #expect(NameValidation.newFolderName(siblings: siblings) == base)
        #expect(NameValidation.newFolderName(siblings: siblings + [entry(base, 3)]) == "\(base) 2")
    }
}
```

`Packages/MTPKit/Tests/TetherCoreTests/EntryFilterTests.swift`:

```swift
import Foundation
import Testing
import MTPKit
@testable import TetherCore

@MainActor
@Suite struct EntryFilterTests {
    private func entry(_ name: String) -> FileEntry {
        FileEntry(objectID: UInt32(name.hashValue & 0xFFFF), parentID: FileEntry.rootID, storageID: 1, name: name,
                  size: 0, modified: nil, isFolder: false)
    }

    @Test func hiddenEntriesAreFilteredButStillClash() async {
        let entries = [entry(".nomedia"), entry("a.jpg")]
        #expect(EntryFilter.visible(entries, showHidden: false).map(\.name) == ["a.jpg"])
        #expect(EntryFilter.visible(entries, showHidden: true).map(\.name) == [".nomedia", "a.jpg"])
        // The browser passes ALL names (hidden included) to the planner, so a hidden clash is still asked about.
        var asked = false
        _ = await UploadPlanner.plan([URL(fileURLWithPath: "/m/.nomedia")], existingNames: Set(entries.map(\.name)),
                                     defaultChoice: nil) { _ in asked = true; return .init(choice: .skip, applyToAll: false) }
        #expect(asked)
    }
}
```

`Packages/MTPKit/Tests/TetherCoreTests/AppSettingsTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/MTPKit --filter "UploadPlannerTests|NameValidationTests|EntryFilterTests|AppSettingsTests"`
Expected: compile errors: `cannot find 'UploadPlanner' in scope`, and so on.

- [ ] **Step 3: Implement `UploadPlanner.swift`**

```swift
import Foundation
import MTPKit

public enum ConflictChoice: Sendable, Equatable {
    case replace, keepBoth, skip
}

public struct ConflictQuestion: Sendable, Equatable {
    public let name: String
    /// Clashes still to come after this one; the prompt offers "Apply to all" when > 0.
    public let remaining: Int

    public init(name: String, remaining: Int) {
        self.name = name
        self.remaining = remaining
    }
}

public struct ConflictAnswer: Sendable, Equatable {
    public let choice: ConflictChoice
    public let applyToAll: Bool

    public init(choice: ConflictChoice, applyToAll: Bool) {
        self.choice = choice
        self.applyToAll = applyToAll
    }
}

public struct PlannedUpload: Sendable, Equatable {
    public let url: URL
    public let conflict: ConflictResolution

    public init(url: URL, conflict: ConflictResolution) {
        self.url = url
        self.conflict = conflict
    }
}

/// Decides how each dropped item handles a name clash, asking the user only about clashes.
@MainActor
public enum UploadPlanner {
    public static func plan(_ urls: [URL], existingNames: Set<String>, defaultChoice: ConflictChoice?,
                            ask: (ConflictQuestion) async -> ConflictAnswer) async -> [PlannedUpload] {
        // A name clashes with the folder or with an earlier item of the same drop.
        var seen = existingNames
        let clashes = urls.map { url in
            let name = url.lastPathComponent
            defer { seen.insert(name) }
            return seen.contains(name)
        }

        var remaining = clashes.filter { $0 }.count
        var remembered = defaultChoice
        var result: [PlannedUpload] = []
        for (url, clash) in zip(urls, clashes) {
            guard clash else {
                result.append(PlannedUpload(url: url, conflict: .fail))
                continue
            }
            remaining -= 1
            let choice: ConflictChoice
            if let remembered {
                choice = remembered
            } else {
                let answer = await ask(ConflictQuestion(name: url.lastPathComponent, remaining: remaining))
                choice = answer.choice
                if answer.applyToAll { remembered = answer.choice }
            }
            switch choice {
            case .skip: continue
            case .replace: result.append(PlannedUpload(url: url, conflict: .replace))
            case .keepBoth: result.append(PlannedUpload(url: url, conflict: .keepBoth))
            }
        }
        return result
    }
}
```

- [ ] **Step 4: Implement `NameValidation.swift`**

```swift
import Foundation
import MTPKit

public enum NameProblem: Error, Equatable, Sendable {
    case empty
    case invalidCharacters
    case taken(String)

    public var message: String {
        switch self {
        case .empty:
            String(localized: "A name can’t be empty.")
        case .invalidCharacters:
            String(localized: "Names can’t contain “/” or be “.” or “..”.")
        case .taken(let name):
            String(localized: "The name “\(name)” is already taken. Please choose a different name.")
        }
    }
}

public enum RenameOutcome: Equatable, Sendable {
    case unchanged
    case valid(String)
    case invalid(NameProblem)
}

public enum NameValidation {
    /// Checks a proposed name for an item called `current` among `siblings` (which may include the item itself).
    /// MTP names are case-sensitive, so a case-only rename is allowed.
    public static func validate(_ proposed: String, current: String, siblings: [FileEntry]) -> RenameOutcome {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .invalid(.empty) }
        if name.contains("/") || name.contains("\0") || name == "." || name == ".." {
            return .invalid(.invalidCharacters)
        }
        if name == current { return .unchanged }
        if siblings.contains(where: { $0.name == name }) { return .invalid(.taken(name)) }
        return .valid(name)
    }

    /// "untitled folder", or "untitled folder 2", … if taken.
    public static func newFolderName(siblings: [FileEntry]) -> String {
        let names = Set(siblings.map(\.name))
        return Transfers.uniqueName(for: String(localized: "untitled folder")) { names.contains($0) }
    }
}
```

- [ ] **Step 5: Implement `EntryFilter.swift`**

```swift
import MTPKit

public enum EntryFilter {
    /// Hides dot-files unless `showHidden` (Android uses them for ".nomedia", ".thumbnails", …).
    public static func visible(_ entries: [FileEntry], showHidden: Bool) -> [FileEntry] {
        showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
    }
}
```

- [ ] **Step 6: Implement `AppSettings.swift`**

```swift
import Foundation

public enum SettingsKey {
    public static let downloadFolderPath = "downloadFolderPath"
    public static let conflictDefault = "conflictDefault"
    public static let showHiddenFiles = "showHiddenFiles"
}

/// The Settings choice for name clashes; `.ask` shows the dialog.
public enum ConflictDefault: String, CaseIterable, Sendable {
    case ask, replace, keepBoth, skip

    public var choice: ConflictChoice? {
        switch self {
        case .ask: nil
        case .replace: .replace
        case .keepBoth: .keepBoth
        case .skip: .skip
        }
    }

    public var title: String {
        switch self {
        case .ask: String(localized: "Ask Every Time")
        case .replace: String(localized: "Replace")
        case .keepBoth: String(localized: "Keep Both")
        case .skip: String(localized: "Skip")
        }
    }
}

public enum AppSettings {
    public static var defaultDownloadFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// The Settings download folder if it still exists as a directory, otherwise ~/Downloads.
    public static func downloadFolder(in defaults: UserDefaults = .standard) -> URL {
        guard let path = defaults.string(forKey: SettingsKey.downloadFolderPath), !path.isEmpty else {
            return defaultDownloadFolder
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return defaultDownloadFolder
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    public static func conflictDefault(in defaults: UserDefaults = .standard) -> ConflictDefault {
        defaults.string(forKey: SettingsKey.conflictDefault).flatMap(ConflictDefault.init(rawValue:)) ?? .ask
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test --package-path Packages/MTPKit`
Expected: all tests pass, including 5 `UploadPlannerTests`, 6 `NameValidationTests`, 1 `EntryFilterTests` and 3 `AppSettingsTests`.

- [ ] **Step 8: Commit**

```bash
git add -A Packages/MTPKit
git commit -m "feat(TetherCore): upload planner, name validation, hidden-file filter, settings"
```

---

### Task 5: File list selection, inline rename, context menu, operations, conflict prompt

**Files:**
- Rewrite: `Tether/FileTableView.swift`
- Create: `Tether/ConflictPrompt.swift`
- Rewrite: `Tether/BrowserView.swift`
- Modify: `Tether/ContentView.swift`

**Interfaces:**
- Consumes:
  - TetherCore: `UploadPlanner`, `NameValidation`, `EntryFilter`, `AppSettings`, `SettingsKey`, `ConflictQuestion`/`ConflictAnswer`/`ConflictChoice` (Task 4)
  - `TransferQueue.enqueueUpload(_:to:conflict:)` (Task 3)
  - `DeviceStore.createFolder/rename/delete` (Plan 1)
  - `TransfersButton` (Plan 1)
- Produces:
  - `FileTableView(entries:selection:renameRequest:actions:)` and `FileTableActions` (below)
  - `BrowserView(selection:)`, which now owns `path`
  - `ConflictPrompt.ask(_:) async -> ConflictAnswer`, which is `@MainActor`
  - Task 6 adds the menu-bar wiring to `BrowserView`

**Behavior:**
- **Selection by ID:** selection is tracked by `objectID` (a `Set<UInt32>` binding). It is restored after every reload or resort, and cleared when the folder changes. This fixes the Plan 1 follow-up where the highlighted rows could point at different files.
- **Starting a rename:** ↩ on exactly one selected row, or *Rename* in the context menu, starts editing the name in place. The base name is pre-selected, without the extension (like Finder).
- **Ending a rename:** ↩ or clicking away commits the new name, and Esc cancels. Refreshes that arrive while a name is being edited are held back until editing ends.
- **Context menu:** right-clicking a row selects it unless it is already part of the selection. The menu offers Open (single folder), Download, Rename (single item), Delete… and New Folder. Right-clicking empty space offers only New Folder.
- **Delete:** asks for confirmation with "This can’t be undone."
- **New Folder:** creates `NameValidation.newFolderName`, selects it, and starts renaming it.
- **Upload:** the drop or Upload button runs `UploadPlanner` with the names of *all* entries, hidden ones included, plus the Settings default. It asks through `ConflictPrompt`, then enqueues each item with its policy.
- **Errors:** operation errors are shown in an alert.

No unit tests: this is AppKit/SwiftUI glue over logic already tested in Task 4. Verify with a build, a launch with no crash, and the manual checklist in Step 7.

- [ ] **Step 1: Rewrite `Tether/FileTableView.swift`**

```swift
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MTPKit

/// What the file list asks its owner to do. All closures run on the main actor.
struct FileTableActions {
    var open: (FileEntry) -> Void
    var dropFiles: ([URL]) -> Void
    var makePromise: (FileEntry) -> NSFilePromiseProvider
    var requestRename: (FileEntry) -> Void
    var commitRename: (FileEntry, String) -> Void
    /// Called once the requested rename has started, so the owner can clear its request.
    var renameStarted: () -> Void
    var editingChanged: (Bool) -> Void
    var download: ([FileEntry]) -> Void
    var delete: ([FileEntry]) -> Void
    var newFolder: () -> Void
}

/// Finder-style list backed by NSTableView: sortable columns, selection by object ID, inline rename,
/// context menu, drag-out via file promises, drop-in of Finder files.
struct FileTableView: NSViewRepresentable {
    var entries: [FileEntry]
    @Binding var selection: Set<UInt32>
    /// Object whose name should be edited as soon as its row exists.
    var renameRequest: UInt32?
    var actions: FileTableActions

    enum Column: String, CaseIterable {
        case name, size, modified

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

        var title: String {
            switch self {
            case .name: String(localized: "Name")
            case .size: String(localized: "Size")
            case .modified: String(localized: "Date Modified")
            }
        }

        var width: CGFloat {
            switch self {
            case .name: 320
            case .size: 90
            case .modified: 170
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileTable()
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            table.addTableColumn(tableColumn)
        }
        table.sortDescriptors = [NSSortDescriptor(key: Column.name.rawValue, ascending: true)]
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openClicked(_:))
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.onReturn = { [weak coordinator = context.coordinator] in coordinator?.returnPressed() }
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.show(entries)
        coordinator.syncSelectionFromParent()
        coordinator.startRenameIfRequested()
    }

    /// Return starts a rename instead of NSTableView's default handling.
    final class FileTable: NSTableView {
        var onReturn: (@MainActor () -> Void)?

        override func keyDown(with event: NSEvent) {
            let plain = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
            if plain, event.keyCode == 36 || event.keyCode == 76, let onReturn {
                onReturn()
                return
            }
            super.keyDown(with: event)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
        var parent: FileTableView
        weak var table: NSTableView?
        private var source: [FileEntry] = []
        private var rows: [FileEntry] = []
        /// Entries that arrived while a name was being edited; applied when editing ends.
        private var pendingEntries: [FileEntry]?
        /// Programmatic selection changes must not be echoed back into the SwiftUI binding.
        private var isApplyingSelection = false
        private var editingID: UInt32?
        private var renameCancelled = false
        private var renameScheduled = false
        private var menuTargets: [FileEntry] = []

        init(parent: FileTableView) { self.parent = parent }

        // MARK: Data

        func show(_ entries: [FileEntry]) {
            if editingID != nil {
                pendingEntries = entries
                return
            }
            guard entries != source else { return }
            source = entries
            resort()
        }

        private func resort() {
            let descriptor = table?.sortDescriptors.first
            let key = descriptor?.key ?? Column.name.rawValue
            let ascending = descriptor?.ascending ?? true
            func less(_ a: FileEntry, _ b: FileEntry) -> Bool {
                switch key {
                case Column.size.rawValue:
                    a.size != b.size ? a.size < b.size : a.name.localizedStandardCompare(b.name) == .orderedAscending
                case Column.modified.rawValue:
                    (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
                default:
                    a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            }
            rows = source.sorted { a, b in
                if a.isFolder != b.isFolder { return a.isFolder } // folders first, like Finder
                return ascending ? less(a, b) : less(b, a)
            }
            isApplyingSelection = true
            table?.reloadData()
            isApplyingSelection = false
            applySelection()
        }

        // MARK: Selection (by object ID)

        private var selectedIDsInTable: Set<UInt32> {
            guard let table else { return [] }
            return Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].objectID : nil })
        }

        private func applySelection() {
            guard let table else { return }
            let indexes = IndexSet(rows.indices.filter { parent.selection.contains(rows[$0].objectID) })
            isApplyingSelection = true
            table.selectRowIndexes(indexes, byExtendingSelection: false)
            isApplyingSelection = false
        }

        func syncSelectionFromParent() {
            if selectedIDsInTable != parent.selection { applySelection() }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection else { return }
            let ids = selectedIDsInTable
            if ids != parent.selection { parent.selection = ids }
        }

        private var selectedEntries: [FileEntry] {
            guard let table else { return [] }
            return table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
        }

        // MARK: Table data source / delegate

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let entry = rows[row]
            let cell = (tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTableCellView)
                ?? makeCell(column)
            switch column {
            case .name:
                cell.textField?.stringValue = entry.name
                cell.imageView?.image = icon(for: entry)
            case .size:
                cell.textField?.stringValue = entry.isFolder
                    ? "—" : ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file)
            case .modified:
                cell.textField?.stringValue = entry.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—"
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            resort()
        }

        @objc func openClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard rows.indices.contains(row) else { return }
            parent.actions.open(rows[row])
        }

        // MARK: Rename

        func returnPressed() {
            let selected = selectedEntries
            guard editingID == nil, selected.count == 1 else { return }
            parent.actions.requestRename(selected[0])
        }

        /// Starts the owner's pending rename on the next run loop turn (never during a SwiftUI update).
        func startRenameIfRequested() {
            guard let id = parent.renameRequest, !renameScheduled,
                  rows.contains(where: { $0.objectID == id }) else { return }
            renameScheduled = true
            Task { @MainActor [weak self] in // next main-actor turn, outside the SwiftUI update
                guard let self else { return }
                self.renameScheduled = false
                self.parent.actions.renameStarted()
                self.beginEditing(objectID: id)
            }
        }

        private func beginEditing(objectID: UInt32) {
            guard let table, let row = rows.firstIndex(where: { $0.objectID == objectID }) else { return }
            let nameColumn = table.column(withIdentifier: Column.name.identifier)
            guard nameColumn >= 0 else { return }
            table.scrollRowToVisible(row)
            table.selectRowIndexes([row], byExtendingSelection: false)
            guard let cell = table.view(atColumn: nameColumn, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let field = cell.textField else { return }
            editingID = objectID
            renameCancelled = false
            field.isEditable = true
            field.delegate = self
            table.window?.makeFirstResponder(field)
            let name = rows[row].name as NSString
            let base = rows[row].isFolder ? name : name.deletingPathExtension as NSString
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: base.length)
            parent.actions.editingChanged(true)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                renameCancelled = true
                control.window?.makeFirstResponder(table) // ends editing → controlTextDidEndEditing
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField, let id = editingID else { return }
            editingID = nil
            let typed = field.stringValue
            field.isEditable = false
            let entry = source.first { $0.objectID == id }
            if let entry { field.stringValue = entry.name } // the refresh after a successful rename shows the new name
            parent.actions.editingChanged(false)
            if !renameCancelled, let entry { parent.actions.commitRename(entry, typed) }
            renameCancelled = false
            if let pending = pendingEntries {
                pendingEntries = nil
                show(pending)
            }
            if table?.window?.firstResponder !== table { table?.window?.makeFirstResponder(table) }
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, editingID == nil else { return }
            let clicked = table.clickedRow
            if rows.indices.contains(clicked) {
                if !table.selectedRowIndexes.contains(clicked) {
                    table.selectRowIndexes([clicked], byExtendingSelection: false) // Finder: right-click selects
                }
                menuTargets = selectedEntries
            } else {
                menuTargets = []
            }
            let targets = menuTargets
            if !targets.isEmpty {
                if targets.count == 1, targets[0].isFolder {
                    menu.addItem(item(String(localized: "Open"), #selector(openFromMenu)))
                }
                menu.addItem(item(targets.count == 1 ? String(localized: "Download")
                                                     : String(localized: "Download \(targets.count) Items"),
                                  #selector(downloadFromMenu)))
                menu.addItem(.separator())
                if targets.count == 1 { menu.addItem(item(String(localized: "Rename"), #selector(renameFromMenu))) }
                menu.addItem(item(targets.count == 1 ? String(localized: "Delete…")
                                                     : String(localized: "Delete \(targets.count) Items…"),
                                  #selector(deleteFromMenu)))
                menu.addItem(.separator())
            }
            menu.addItem(item(String(localized: "New Folder"), #selector(newFolderFromMenu)))
        }

        private func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }

        @objc private func openFromMenu() { if let entry = menuTargets.first { parent.actions.open(entry) } }
        @objc private func downloadFromMenu() { parent.actions.download(menuTargets) }
        @objc private func renameFromMenu() { if let entry = menuTargets.first { parent.actions.requestRename(entry) } }
        @objc private func deleteFromMenu() { parent.actions.delete(menuTargets) }
        @objc private func newFolderFromMenu() { parent.actions.newFolder() }

        // MARK: Drag out

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            parent.actions.makePromise(rows[row])
        }

        // MARK: Drop in

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            if (info.draggingSource as? NSTableView) === tableView { return [] }
            guard info.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                        options: [.urlReadingFileURLsOnly: true]) else { return [] }
            tableView.setDropRow(-1, dropOperation: .on) // whole table = current folder
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                                 options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  !urls.isEmpty else { return false }
            parent.actions.dropFiles(urls)
            return true
        }

        // MARK: Cells

        private func makeCell(_ column: Column) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = column.identifier
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            if column == .name {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                ])
            } else {
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
                if column == .size { text.alignment = .right }
            }
            NSLayoutConstraint.activate([
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func icon(for entry: FileEntry) -> NSImage {
            let type: UTType = entry.isFolder
                ? .folder
                : UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
            return NSWorkspace.shared.icon(for: type)
        }
    }
}
```

- [ ] **Step 2: Create `Tether/ConflictPrompt.swift`**

```swift
import AppKit
import TetherCore

/// Finder-style "an item with this name already exists" alert, shown as a sheet on the key window.
@MainActor
enum ConflictPrompt {
    static func ask(_ question: ConflictQuestion) async -> ConflictAnswer {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "An item named “\(question.name)” already exists in this folder.")
        alert.informativeText = String(localized: "Do you want to replace it with the one you’re copying?")
        alert.addButton(withTitle: String(localized: "Replace"))   // .alertFirstButtonReturn
        alert.addButton(withTitle: String(localized: "Keep Both")) // .alertSecondButtonReturn
        let skip = alert.addButton(withTitle: String(localized: "Skip"))
        skip.keyEquivalent = "\u{1b}" // Esc skips
        if question.remaining > 0 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(localized: "Apply to all")
        }

        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        let choice: ConflictChoice = switch response {
        case .alertFirstButtonReturn: .replace
        case .alertSecondButtonReturn: .keepBoth
        default: .skip
        }
        return ConflictAnswer(choice: choice, applyToAll: alert.suppressionButton?.state == .on)
    }
}
```

- [ ] **Step 3: Rewrite `Tether/BrowserView.swift`**

```swift
import SwiftUI
import MTPKit
import TetherCore

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    let selection: StorageSelection
    @State private var path: [FileEntry] = []
    @State private var selectedIDs: Set<UInt32> = []
    @State private var renameRequest: UInt32?
    @State private var isEditingName = false
    @State private var pendingDelete: [FileEntry] = []
    @State private var problem: String?
    @AppStorage(SettingsKey.showHiddenFiles) private var showHiddenFiles = false

    private var folder: FolderRef {
        FolderRef(deviceID: selection.deviceID, storageID: selection.storageID,
                  folderID: path.last?.objectID ?? FileEntry.rootID)
    }

    private var title: String {
        path.last?.name ?? model.devices.storage(for: folder)?.name ?? String(localized: "Phone")
    }

    /// Every entry, hidden ones included (used for name-clash checks).
    private var allEntries: [FileEntry] { model.devices.listings[folder]?.entries ?? [] }
    private var visibleEntries: [FileEntry] { EntryFilter.visible(allEntries, showHidden: showHiddenFiles) }
    private var selectedEntries: [FileEntry] { visibleEntries.filter { selectedIDs.contains($0.objectID) } }

    var body: some View {
        let listing = model.devices.listings[folder]
        FileTableView(entries: visibleEntries, selection: $selectedIDs, renameRequest: renameRequest,
                      actions: tableActions)
            .overlay { overlay(for: listing) }
            .navigationTitle(title)
            .navigationSubtitle(listing?.isUpdating == true ? String(localized: "Updating…") : "")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button(action: goUp) { Label("Back", systemImage: "chevron.left") }
                        .disabled(path.isEmpty)
                }
                ToolbarItem {
                    Button(action: refresh) { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                ToolbarItem {
                    Button(action: newFolder) { Label("New Folder", systemImage: "folder.badge.plus") }
                }
                ToolbarItem {
                    Button(action: chooseFilesToUpload) { Label("Upload", systemImage: "square.and.arrow.up") }
                }
                ToolbarItem { TransfersButton() }
            }
            .task(id: folder) { await model.devices.refresh(folder) }
            .onChange(of: folder) {
                selectedIDs = []
                renameRequest = nil
            }
            .confirmationDialog(deleteTitle, isPresented: isConfirmingDelete) {
                let items = pendingDelete
                Button(String(localized: "Delete"), role: .destructive) { delete(items) }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text("This can’t be undone.")
            }
            .alert(String(localized: "The Operation Couldn’t Be Completed"), isPresented: isShowingProblem) {
                Button(String(localized: "OK")) {}
            } message: {
                Text(problem ?? "")
            }
    }

    // MARK: Overlay

    @ViewBuilder
    private func overlay(for listing: DeviceStore.Listing?) -> some View {
        if listing == nil || (listing!.isUpdating && listing!.entries.isEmpty) {
            ProgressView()
        } else if let error = listing?.error, listing?.entries.isEmpty == true {
            ContentUnavailableView {
                Label("Can’t Read This Folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.localizedDescription)
            } actions: {
                Button("Try Again", action: refresh)
            }
        } else if visibleEntries.isEmpty {
            ContentUnavailableView("Empty Folder", systemImage: "folder",
                                   description: Text("Drop files here to copy them to the phone."))
                .allowsHitTesting(false)
        }
    }

    // MARK: Table wiring

    private var tableActions: FileTableActions {
        FileTableActions(
            open: open,
            dropFiles: upload,
            makePromise: { FilePromise.provider(for: $0, deviceID: selection.deviceID, queue: model.transfers) },
            requestRename: { renameRequest = $0.objectID },
            commitRename: commitRename,
            renameStarted: { renameRequest = nil },
            editingChanged: { isEditingName = $0 },
            download: download,
            delete: requestDelete,
            newFolder: newFolder)
    }

    // MARK: Actions

    private func goUp() {
        if !path.isEmpty { path.removeLast() }
    }

    private func refresh() {
        let folder = self.folder
        Task { await model.devices.refresh(folder) }
    }

    private func open(_ entry: FileEntry) {
        if entry.isFolder { path.append(entry) }
    }

    private func newFolder() {
        let name = NameValidation.newFolderName(siblings: allEntries)
        let folder = self.folder
        Task {
            do {
                let created = try await model.devices.createFolder(named: name, in: folder)
                selectedIDs = [created.objectID]
                renameRequest = created.objectID
            } catch {
                problem = MTPError.from(error).localizedDescription
            }
        }
    }

    private func commitRename(_ entry: FileEntry, _ proposed: String) {
        switch NameValidation.validate(proposed, current: entry.name, siblings: allEntries) {
        case .unchanged:
            return
        case .invalid(let reason):
            problem = reason.message
        case .valid(let name):
            let folder = self.folder
            Task {
                do { try await model.devices.rename(entry, in: folder, to: name) }
                catch { problem = MTPError.from(error).localizedDescription }
            }
        }
    }

    private func requestDelete(_ entries: [FileEntry]) {
        if !entries.isEmpty { pendingDelete = entries }
    }

    private func delete(_ entries: [FileEntry]) {
        pendingDelete = []
        let folder = self.folder
        Task {
            do {
                try await model.devices.delete(entries, in: folder)
                selectedIDs.subtract(entries.map(\.objectID))
            } catch {
                problem = MTPError.from(error).localizedDescription
            }
        }
    }

    private func download(_ entries: [FileEntry]) {
        let directory = AppSettings.downloadFolder()
        for entry in entries {
            model.transfers.enqueueDownload(entry, deviceID: selection.deviceID, into: directory)
        }
    }

    private func upload(_ urls: [URL]) {
        let folder = self.folder
        let names = Set(allEntries.map(\.name)) // hidden names clash too
        let defaultChoice = AppSettings.conflictDefault().choice
        Task {
            let planned = await UploadPlanner.plan(urls, existingNames: names, defaultChoice: defaultChoice,
                                                   ask: ConflictPrompt.ask)
            for item in planned {
                model.transfers.enqueueUpload(item.url, to: folder, conflict: item.conflict)
            }
        }
    }

    private func chooseFilesToUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Upload")
        panel.begin { response in
            guard response == .OK else { return }
            upload(panel.urls)
        }
    }

    // MARK: Dialog state

    private var deleteTitle: String {
        pendingDelete.count == 1
            ? String(localized: "Delete “\(pendingDelete[0].name)”?")
            : String(localized: "Delete \(pendingDelete.count) items?")
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })
    }

    private var isShowingProblem: Binding<Bool> {
        Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
    }
}
```

- [ ] **Step 4: Remove `path` from `Tether/ContentView.swift`**

1. Delete the line `@State private var path: [FileEntry] = []`.
2. Change `BrowserView(selection: selection, path: $path)` to `BrowserView(selection: selection)`. Keep `.id(selection)`, so each storage gets a fresh browser with an empty path.
3. Replace the `.onChange(of: selection)` block with:

```swift
        .onChange(of: selection) {
            if selection == nil { ensureSelection() } // empty-space click deselects; keep a ready storage selected
        }
```

- [ ] **Step 5: Generate, build and launch**

Run: `xcodegen generate && xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Debug -derivedDataPath DerivedData build 2>&1 | grep -E "error:|warning: .*Tether/|BUILD"`
Expected: `** BUILD SUCCEEDED **`, with no warnings from `Tether/`.

Run: `DerivedData/Build/Products/Debug/Tether.app/Contents/MacOS/Tether -UseFakeDevices YES & PID=$!; sleep 4; kill -0 $PID && echo alive; kill $PID`
Expected: `alive` (no crash at launch).

- [ ] **Step 6: Commit**

```bash
git add -A Tether
git commit -m "feat(app): rename, delete, new folder, context menu and conflict prompt; selection tracked by ID"
```

- [ ] **Step 7: Manual checklist** (for the human; record the results in the PR)

With `-UseFakeDevices YES`:
1. Select `notes.txt` and press ↩. The base name `notes` is highlighted. Type `memo`, press ↩, and the row becomes `memo.txt`. Press ↩ again, then Esc, and the name is unchanged.
2. Rename to the name of an existing file. An alert says the name is taken.
3. Right-click empty space → New Folder. "untitled folder" appears in rename mode.
4. Select two files, right-click → Delete 2 Items… → Delete. They disappear.
5. Drag a phone file to the Desktop, then drag it back. The dialog appears, and Keep Both creates `name 2.ext`. Drop two clashing files at once. "Apply to all" is offered.
6. Sort by Size with a row selected. The same file stays selected.

---

### Task 6: Menu-bar commands, Settings window, global Transfers button

**Files:**
- Create: `Tether/BrowserCommands.swift`
- Create: `Tether/SettingsView.swift`
- Modify: `Tether/BrowserView.swift` (focused actions; remove `TransfersButton` from its toolbar)
- Modify: `Tether/ContentView.swift` (Transfers button in the window toolbar)
- Modify: `Tether/TetherApp.swift`

**Interfaces:**
- Consumes: `BrowserView` actions (Task 5), `SettingsKey`, `ConflictDefault`, `AppSettings` (Task 4), `TransfersButton` (Plan 1).
- Produces:
  - `struct BrowserActions`
  - `FocusedValues.browserActions`
  - `BrowserCommands: Commands`
  - `SettingsView`

**Behavior:**
- **Menu commands:**

  | Menu | Item | Shortcut |
  |---|---|---|
  | File | New Folder | ⇧⌘N |
  | File | Open | ⌘↓ |
  | File | Download | ⌥⌘D |
  | File | Rename | — |
  | File | Delete… | ⌘⌫ |
  | View | Refresh | ⌘R |
  | View | Show Hidden Files | ⇧⌘. |
  | Go | Enclosing Folder | ⌘↑ |

- **Disabled items:** each item is disabled when it doesn't apply.
- **While editing a name:** Delete and Rename are disabled, so ⌘⌫ edits text instead of deleting files.
- **Transfers button:** moves to the window toolbar, so failures stay visible with no phone connected.

- [ ] **Step 1: Create `Tether/BrowserCommands.swift`**

```swift
import SwiftUI
import TetherCore

/// What the focused browser can do right now; `nil` members disable their menu items.
struct BrowserActions {
    var newFolder: () -> Void
    var refresh: () -> Void
    var goUp: (() -> Void)?
    var open: (() -> Void)?
    var download: (() -> Void)?
    var rename: (() -> Void)?
    var delete: (() -> Void)?
}

extension FocusedValues {
    @Entry var browserActions: BrowserActions?
}

struct BrowserCommands: Commands {
    @FocusedValue(\.browserActions) private var actions
    @AppStorage(SettingsKey.showHiddenFiles) private var showHiddenFiles = false

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Folder") { actions?.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Divider()
            Button("Open") { actions?.open?() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(actions?.open == nil)
            Button("Download") { actions?.download?() }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(actions?.download == nil)
            Button("Rename") { actions?.rename?() }
                .disabled(actions?.rename == nil)
            Button("Delete…") { actions?.delete?() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(actions?.delete == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("Refresh") { actions?.refresh() }
                .keyboardShortcut("r")
                .disabled(actions == nil)
            Toggle("Show Hidden Files", isOn: $showHiddenFiles)
                .keyboardShortcut(".", modifiers: [.command, .shift])
        }
        CommandMenu("Go") {
            Button("Enclosing Folder") { actions?.goUp?() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(actions?.goUp == nil)
        }
    }
}
```

- [ ] **Step 2: Publish the actions from `BrowserView`**

In `Tether/BrowserView.swift`:

1. In the `.toolbar`, delete `ToolbarItem { TransfersButton() }`.
2. Add this modifier after `.onChange(of: folder) { … }`:

```swift
            .focusedSceneValue(\.browserActions, menuActions)
```

3. Add this computed property in the `// MARK: Table wiring` section:

```swift
    private var menuActions: BrowserActions {
        let selected = selectedEntries
        let editing = isEditingName
        return BrowserActions(
            newFolder: newFolder,
            refresh: refresh,
            goUp: path.isEmpty ? nil : goUp,
            open: selected.count == 1 && selected[0].isFolder ? { open(selected[0]) } : nil,
            download: selected.isEmpty ? nil : { download(selected) },
            rename: selected.count == 1 && !editing ? { renameRequest = selected[0].objectID } : nil,
            delete: selected.isEmpty || editing ? nil : { requestDelete(selected) })
    }
```

- [ ] **Step 3: Put the Transfers button in the window toolbar**

In `Tether/ContentView.swift`, add this modifier to the `NavigationSplitView`, after `.onChange(of: model.devices.devices) { ensureSelection() }`:

```swift
        .toolbar {
            ToolbarItem(placement: .primaryAction) { TransfersButton() }
        }
```

- [ ] **Step 4: Create `Tether/SettingsView.swift`**

```swift
import SwiftUI
import TetherCore

struct SettingsView: View {
    @AppStorage(SettingsKey.downloadFolderPath) private var downloadFolderPath = AppSettings.defaultDownloadFolder.path
    @AppStorage(SettingsKey.conflictDefault) private var conflictDefault = ConflictDefault.ask
    @AppStorage(SettingsKey.showHiddenFiles) private var showHiddenFiles = false

    var body: some View {
        Form {
            LabeledContent("Download to") {
                HStack {
                    Text(AppSettings.downloadFolder().lastPathComponent)
                        .help(AppSettings.downloadFolder().path)
                    Button("Choose…", action: chooseFolder)
                }
            }
            Picker("When a name already exists", selection: $conflictDefault) {
                ForEach(ConflictDefault.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Show hidden files", isOn: $showHiddenFiles)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = AppSettings.downloadFolder()
        panel.prompt = String(localized: "Choose")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            downloadFolderPath = url.path
        }
    }
}
```

- [ ] **Step 5: Register commands and the Settings scene in `Tether/TetherApp.swift`**

Replace `var body: some Scene { … }` with:

```swift
    var body: some Scene {
        Window("Tether", id: "main") {
            ContentView()
                .environment(model)
                .task { await model.start() }
                .frame(minWidth: 720, minHeight: 420)
        }
        .commands { BrowserCommands() }

        Settings {
            SettingsView()
        }
    }
```

- [ ] **Step 6: Generate, build and launch**

Run: `xcodegen generate && xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Debug -derivedDataPath DerivedData build 2>&1 | grep -E "error:|warning: .*Tether/|BUILD"`
Expected: `** BUILD SUCCEEDED **`, with no warnings from `Tether/`.

Run: `DerivedData/Build/Products/Debug/Tether.app/Contents/MacOS/Tether -UseFakeDevices YES & PID=$!; sleep 4; kill -0 $PID && echo alive; kill $PID`
Expected: `alive`

- [ ] **Step 7: Commit**

```bash
git add -A Tether
git commit -m "feat(app): menu-bar commands, Settings window, window-level Transfers button"
```

- [ ] **Step 8: Manual checklist** (for the human)

With `-UseFakeDevices YES`:
1. **Menus:** the File, View and Go menus show the items above, with their shortcuts.
2. **Navigation:** ⌘↓ on a selected folder opens it, and ⌘↑ goes back.
3. **Delete:** ⌘⌫ on a selection asks for confirmation. While a name is being edited, ⌘⌫ only edits the text.
4. **Hidden files:** ⇧⌘. shows and hides hidden files. Add a file named `.hidden` by dropping it in to check.
5. **Settings (⌘,):**
   - Choose a download folder. ⌥⌘D then downloads there.
   - Set "When a name already exists" to Keep Both, and dropping a clashing file no longer asks.
6. **Transfers button:** unplug, or pick the locked Galaxy so no storage is selected. The Transfers button is still in the toolbar.

---

## Spec coverage (Plan 2a)

| Spec / follow-up | Task |
|---|---|
| §4: conflict dialog (Replace / Keep Both / Skip, Apply to all) | 2, 3, 4, 5 |
| §4: Replace = delete then upload (done safely: upload first, then swap) | 2 |
| §4: delete with confirmation; rename inline; new folder in rename mode | 5 |
| §5: keyboard ⌘↑ ↩ ⌘⌫ ⇧⌘N ⌘R; actions also in context menus and the menu bar | 5, 6 |
| §5: Settings: download folder, conflict default, hidden files | 4, 6 |
| §5: Transfers button in the toolbar | 6 |
| Follow-up: table selection by object ID (before Delete UI) | 5 |
| Follow-up: stable device identity (serial) | 1 |
| Follow-up: old path applied to a newly selected storage | 5 (path owned by BrowserView, reset via `.id`) |
| §5: icon view, ⌘1/⌘2, thumbnails, Quick Look, error states, Image Capture, String Catalog, VoiceOver; §6 diagnostics; §7 UI tests | Plan 2b |
