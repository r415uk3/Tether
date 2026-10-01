# Tether Rich Browsing (Plan 2b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** browse a phone the way Finder browses a disk:
- an icon view with photo and video thumbnails (⌘1 / ⌘2 to switch views)
- Quick Look on Space
- every operation safe across an unplug/replug

The plan also closes the top two Plan 2a follow-ups: a cheap per-file check before downloads, and connection sessions.

**Architecture:**
- **MTPKit** gains two per-object calls on `MTPDevice`:
  - `objectInfo(objectID:)` (GetObjectInfo), replacing the parent-folder listing used to verify an item before acting on it
  - `thumbnail(objectID:)`
- **Connection sessions:** each open device gets a UUID `session`.
  - `FolderRef` carries the session it was listed in. `LocalMTPService` rejects folder-scoped calls from an older session with `.phoneReconnected`.
  - Rename and delete take the entry and its folder, and verify the entry before touching it.
- **TetherCore** gains two tested caches: `ThumbnailStore` (memory plus disk) and `PreviewCache` (Quick Look downloads).
- **The app** gains:
  - an `NSCollectionView` icon view that shares the list's actions
  - a rename sheet for the icon view
  - a `QuickLookController` attached to the list and the grid through the responder chain

**Tech Stack:** Swift 6 language mode, SwiftUI, AppKit (`NSCollectionView`, `QLPreviewPanel` from Quartz/QuickLookUI), CryptoKit (cache keys), libmtp (`LIBMTP_Get_Filemetadata`, `LIBMTP_Get_Thumbnail`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-01-tether-design.md` (§3 ThumbnailService, §4 Quick Look, §5 icon/list views, ⌘1/⌘2, Space)
**Follow-ups addressed:** `docs/superpowers/notes/2026-10-02-plan2a-followups.md` ("Do first in Plan 2b")

**Plan series:**
- **2b (this plan):** rich browsing.
- **2c:**
  - Image Capture detection and the "Release" button
  - the full set of empty and error screens
  - English and Russian String Catalog
  - VoiceOver
  - Help → Copy Diagnostics
  - XCUITest
  - Liquid Glass polish
- **3:** distribution.

**Branching:** `feat/rich-browsing` from `main`, with a single PR into `main`. It is not stacked.

## Global Constraints

- **Platform and language:** minimum macOS 15.0, Swift 6 language mode with strict concurrency, and no `@preconcurrency` imports. Use `Unchecked<T>` for AppKit/XPC values that cross isolation.
- **Byte counts:** file sizes and byte counts are `UInt64`.
- **Root folder:** the MTP root folder ID is `FileEntry.rootID` (`0xFFFFFFFF`). libmtp's root `parent_id` 0 is normalized to `rootID`.
- **Localization:** user-facing strings use `String(localized:)` or `LocalizedStringKey`.
- **Thumbnails (spec §3):** fetched lazily at the lowest (`.background`) device priority. They are cached in memory and on disk under `~/Library/Caches/dev.tether.Tether/thumbnails`, keyed by device ID + storage + object ID + size + modified date.
- **Quick Look (spec §4):** Space downloads the file into `~/Library/Caches/dev.tether.Tether/preview`, then opens `QLPreviewPanel`. The preview cache is cleared on quit.
- **View shortcuts (spec §5):** ⌘1 shows icons and ⌘2 shows the list (as in Finder). Quick Look is Space or ⌘Y.
- **Never act on a stale handle:**
  - Rename, delete and download verify the object (ID, name, kind, size, parent, storage) right before acting.
  - Folder-scoped calls from an older connection session fail with `.phoneReconnected`.
- **Project file:** the Xcode project is generated from `project.yml`. Run `xcodegen generate` after adding files under `Tether/`.

## Review Focus

1. **Replug while a folder is open:** the user then renames or deletes an item from the old listing. The operation must be refused (`.phoneReconnected`) and must never touch whatever object now has that handle. Pinned in Task 2, `staleSessionRenameAndDeleteAreRefused`.
2. **Handle reuse:** downloading an entry whose object ID now belongs to a different file must fail with `.notFound`, leave no partial file, and not list the parent folder. Pinned in Task 1, `mismatchedObjectFailsWithoutListing`.
3. **Transient thumbnail failures:** a thumbnail fetch that throws (busy or disconnected) must not mark the item "no thumbnail" forever; a later request retries. Pinned in Task 3, `transientFailureIsRetried`.
4. **Changed files:** a file changed on the phone (new size or date, same handle) gets a new thumbnail and a fresh Quick Look copy, not the stale cached one. Pinned in Task 3, `changedItemGetsNewThumbnail`, and Task 4, `changedItemIsDownloadedAgain`.
5. **Preview name clashes:** two different files with the same name (in different folders) previewed one after the other must not overwrite each other in the preview cache. Pinned in Task 4, `sameNameDifferentItemsDoNotCollide`.

---

## File Structure

```
Packages/MTPKit/Sources/MTPKit/
  MTPDevice.swift                 # MODIFY: objectInfo(objectID:) (T1), thumbnail(objectID:) (T3)
  FakeDevice.swift                # MODIFY: objectInfo, listFolderCalls (T1); thumbnails (T3)
  Transfers+Download.swift        # MODIFY: verify via objectInfo (T1)
  Models.swift                    # MODIFY: DeviceInfo.session, FolderRef.session (T2)
  MTPError.swift                  # MODIFY: .phoneReconnected (T2)
  MTPService.swift                # MODIFY: rename/delete by entry+folder (T2), thumbnail (T3)
  LocalMTPService.swift           # MODIFY: sessions + checks (T2), thumbnail (T3)
  XPC/XPCMessages.swift, XPC/MTPXPCEndpoint.swift, XPC/XPCMTPService.swift   # MODIFY (T2, T3)
Packages/MTPKit/Sources/TetherCore/
  DeviceStore.swift               # MODIFY: session-aware apply, session(for:), new rename/delete calls (T2)
  ItemKey.swift                   # NEW: cache key + hashed file name (T3)
  ThumbnailStore.swift            # NEW (T3)
  PreviewCache.swift              # NEW (T4)
  AppModel.swift                  # MODIFY: thumbnails (T3), previews (T4)
  AppSettings.swift               # MODIFY: BrowserViewMode + key (T5)
MTPHelper/LibMTPDevice.swift      # MODIFY: objectInfo (T1), thumbnail (T3)
Tether/
  FileGridView.swift              # NEW: NSCollectionView icon view (T5)
  RenameSheet.swift               # NEW (T5)
  BrowserView.swift               # MODIFY: sessions (T2), view modes + sheet (T5), Quick Look (T6)
  BrowserCommands.swift           # MODIFY: ⌘1/⌘2 (T5), Quick Look ⌘Y (T6)
  FileTableView.swift             # MODIFY: Space + preview panel control (T6)
  QuickLookController.swift       # NEW (T6)
  TetherApp.swift                 # MODIFY: clear preview cache on quit (T6)
```

Run every command from the repo root, `~/Tether`.

---

### Task 1: Verify an item with GetObjectInfo instead of listing its folder

**Files:**
- Modify: `Packages/MTPKit/Sources/MTPKit/MTPDevice.swift`, `FakeDevice.swift`, `Transfers+Download.swift`
- Modify: `MTPHelper/LibMTPDevice.swift`
- Test: `Packages/MTPKit/Tests/MTPKitTests/DownloadTests.swift`

**Interfaces:**
- Consumes: `Transfers.verify(_:on:)` (Plan 2a: currently lists `entry.parentID`) and `FakeDevice` fault injection.
- Produces:
  - `MTPDevice.objectInfo(objectID: UInt32) throws -> FileEntry?`. It returns `nil` when the object doesn't exist.
  - `FakeDevice.listFolderCalls: Int` (public, test inspection).
  - `Transfers.verify(_:on:)` now compares `objectInfo` against the entry: name, isFolder, size (files only), parentID and storageID. It throws `.notFound` on any mismatch.

**FakeDevice rule:**
- `objectInfo` throws `.deviceDisconnected` after a disconnect.
- It does **not** consume injected faults. A fault injected for a test therefore still hits the transfer itself, which restores the `.partial` cleanup coverage the Plan 2a follow-up flagged.

- [ ] **Step 1: Write the failing tests**

Add inside `DownloadTests` (`Packages/MTPKit/Tests/MTPKitTests/DownloadTests.swift`):

```swift
    @Test func verificationDoesNotListTheParentFolder() throws {
        let camera = device.addFolder("Camera")
        let file = device.addFile("a.jpg", data: Data(count: 10), in: camera.objectID)
        let before = device.listFolderCalls
        _ = try Transfers.download(file, from: device, into: try makeTempDirectory()) { _, _ in true }
        #expect(device.listFolderCalls == before)
    }

    @Test func mismatchedObjectFailsWithoutListing() throws {
        let file = device.addFile("a.jpg", data: Data(count: 10))
        var stale = file
        stale.name = "other.jpg" // same handle, different object now
        let dir = try makeTempDirectory()
        let before = device.listFolderCalls
        #expect(throws: MTPError.notFound) {
            try Transfers.download(stale, from: device, into: dir) { _, _ in true }
        }
        #expect(device.listFolderCalls == before)
        #expect(try contents(of: dir).isEmpty)
    }

    @Test func injectedFaultReachesTheTransferAndPartialIsRemoved() throws {
        let file = device.addFile("big.bin", data: Data(count: 40_960))
        device.inject(.disconnectAfter(bytes: 8192))
        let dir = try makeTempDirectory()
        let progress = Log<UInt64>()
        #expect(throws: MTPError.deviceDisconnected) {
            try Transfers.download(file, from: device, into: dir) { done, _ in progress.append(done); return true }
        }
        #expect(!progress.items.isEmpty) // bytes moved before the fault: the transfer really started
        #expect(try contents(of: dir).isEmpty)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/MTPKit --filter DownloadTests`
Expected: compile error `value of type 'FakeDevice' has no member 'listFolderCalls'`.

- [ ] **Step 3: Add `objectInfo` to the protocol**

In `MTPDevice.swift`, add to `protocol MTPDevice` after `listFolder`:

```swift
    /// The object's current metadata (GetObjectInfo), or nil if no object has this handle.
    func objectInfo(objectID: UInt32) throws -> FileEntry?
```

- [ ] **Step 4: Implement it in `FakeDevice`**

In `FakeDevice.swift`:

1. Add a stored property next to the other private state: `private var listCalls = 0`.
2. Add the public counter in the "Test setup and inspection" section:

```swift
    /// Number of `listFolder` calls so far (tests assert that verification doesn't list).
    public var listFolderCalls: Int { lock.withLock { listCalls } }
```

3. At the top of `listFolder(storageID:folderID:)`, before `try beginSimple()`, add `lock.withLock { listCalls += 1 }`.
4. Add the method in the `// MARK: MTPDevice` section:

```swift
    /// Never consumes injected faults, so a fault injected for a test still hits the operation under test.
    public func objectInfo(objectID: UInt32) throws -> FileEntry? {
        try lock.withLock {
            if disconnected { throw MTPError.deviceDisconnected }
            return nodes[objectID]?.entry
        }
    }
```

- [ ] **Step 5: Verify with `objectInfo` in `Transfers+Download.swift`**

Replace the body of `static func verify(_ entry: FileEntry, on device: any MTPDevice) throws` with:

```swift
        guard let current = try device.objectInfo(objectID: entry.objectID),
              current.name == entry.name,
              current.isFolder == entry.isFolder,
              current.parentID == entry.parentID,
              current.storageID == entry.storageID,
              entry.isFolder || current.size == entry.size else {
            throw MTPError.notFound
        }
```

Keep the doc comment above it, updated to read: "Refuses to act on a handle that no longer names this item (e.g. after Android renumbered objects on reconnect). One GetObjectInfo, no folder listing."

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --package-path Packages/MTPKit`
Expected: all tests pass, including the 3 new `DownloadTests`.

- [ ] **Step 7: Implement `objectInfo` in `LibMTPDevice`**

In `MTPHelper/LibMTPDevice.swift`:

1. Extract the `FileEntry` construction used in `listFolder` into a helper. Keep the root normalization added in Plan 2a:

```swift
    /// Converts a libmtp file record; libmtp reports root children with parent_id 0.
    private static func entry(from f: UnsafeMutablePointer<LIBMTP_file_t>) -> FileEntry {
        FileEntry(
            objectID: f.pointee.item_id,
            parentID: f.pointee.parent_id == 0 ? FileEntry.rootID : f.pointee.parent_id,
            storageID: f.pointee.storage_id,
            name: f.pointee.filename.map { String(cString: $0) } ?? "",
            size: f.pointee.filesize,
            modified: f.pointee.modificationdate == 0 ? nil
                : Date(timeIntervalSince1970: TimeInterval(f.pointee.modificationdate)),
            isFolder: f.pointee.filetype == LIBMTP_FILETYPE_FOLDER)
    }
```

2. Make `listFolder` use `entries.append(Self.entry(from: f))`.

3. Add:

```swift
    func objectInfo(objectID: UInt32) throws -> FileEntry? {
        let h = try requireHandle()
        LIBMTP_Clear_Errorstack(h)
        guard let f = LIBMTP_Get_Filemetadata(h, objectID) else {
            // A vanished handle is "no such object"; a dead connection must still surface as such.
            if LIBMTP_Get_Errorstack(h) != nil, case .deviceDisconnected = lastError(h) {
                throw MTPError.deviceDisconnected
            }
            LIBMTP_Clear_Errorstack(h)
            return nil
        }
        defer { LIBMTP_destroy_file_t(f) }
        return Self.entry(from: f)
    }
```

- [ ] **Step 8: Build the app**

Run: `xcodegen generate && xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Debug -derivedDataPath DerivedData build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 9: Commit**

```bash
git add -A Packages/MTPKit MTPHelper
git commit -m "perf: verify items with GetObjectInfo instead of listing the parent folder"
```

---

### Task 2: Connection sessions: refuse calls from an older connection

**Files:**
- Modify: `Packages/MTPKit/Sources/MTPKit/Models.swift`, `MTPError.swift`, `MTPService.swift`, `LocalMTPService.swift`
- Modify: `Packages/MTPKit/Sources/MTPKit/XPC/XPCMessages.swift`, `XPC/MTPXPCEndpoint.swift`, `XPC/XPCMTPService.swift`
- Modify: `Packages/MTPKit/Sources/TetherCore/DeviceStore.swift`
- Modify: `Tether/BrowserView.swift`
- Modify (tests): every call site of `rename(objectID:deviceID:to:)` and `delete(objectID:deviceID:)` (at least `LocalMTPServiceTests.swift` and the `FlakyService` double in `DeviceStoreTests.swift`; grep for both)
- Test: `Packages/MTPKit/Tests/MTPKitTests/SessionTests.swift` (new), `Packages/MTPKit/Tests/TetherCoreTests/DeviceStoreTests.swift` (add)

**Interfaces:**
- Consumes: `Transfers.verify` (Task 1), `LocalMTPService.publicIDs` (Plan 2a), `DeviceStore.onDeviceBecameReady` (Plan 2a).
- Produces:
  - **`DeviceInfo.session`:** `public var session: UUID?`, the last `init` parameter, defaulting to `nil`. It is set to a fresh `UUID()` each time `LocalMTPService` opens the device.
  - **`FolderRef.session`:** `public let session: UUID?`, `init(deviceID:storageID:folderID: = rootID, session: UUID? = nil)`. `nil` means "don't check".
  - **`MTPError.phoneReconnected`**, with the message "The phone was reconnected. Open the folder again and retry."
  - **New `MTPService` requirements** that replace the objectID-based ones:
    - `func rename(_ entry: FileEntry, in folder: FolderRef, to newName: String) async throws`
    - `func delete(_ entry: FileEntry, in folder: FolderRef) async throws`
  - **`LocalMTPService` checks:** when `folder.session` is non-nil and differs from the device's current session, `list`, `createFolder`, `upload`, `rename` and `delete` throw `.phoneReconnected`. Rename and delete also `Transfers.verify` the entry first.
  - **`DeviceStore.session(for deviceID: DeviceID) -> UUID?`**
  - **`DeviceStore.apply` on a session change:** a ready device whose session changed is treated like a newly ready one. Its storages and listings are dropped, `onDeviceBecameReady` fires and storages reload.

- [ ] **Step 1: Write the failing tests**

`Packages/MTPKit/Tests/MTPKitTests/SessionTests.swift`:

```swift
import Foundation
import Testing
@testable import MTPKit

@Suite struct SessionTests {
    let provider = FakeDeviceProvider()
    let device = FakeDevice(id: "serial-ABC")

    private func makeService() async throws -> (LocalMTPService, UUID) {
        provider.attach(device, as: "14-4")
        let service = LocalMTPService(provider: provider)
        let session = try #require(try await service.devices().first?.session)
        return (service, session)
    }

    @Test func eachOpenGetsANewSession() async throws {
        let (service, first) = try await makeService()
        provider.detach("14-4")
        await service.rescan()
        provider.attach(device, as: "14-7")
        await service.rescan()
        let second = try #require(try await service.devices().first?.session)
        #expect(first != second)
    }

    @Test func staleSessionIsRefusedForFolderCalls() async throws {
        let (service, session) = try await makeService()
        device.addFolder("DCIM")
        let current = FolderRef(deviceID: "serial-ABC", storageID: 1, session: session)
        let stale = FolderRef(deviceID: "serial-ABC", storageID: 1, session: UUID())
        let unchecked = FolderRef(deviceID: "serial-ABC", storageID: 1)
        #expect(try await service.list(current).map(\.name) == ["DCIM"])
        #expect(try await service.list(unchecked).map(\.name) == ["DCIM"])
        await #expect(throws: MTPError.phoneReconnected) { try await service.list(stale) }
        await #expect(throws: MTPError.phoneReconnected) { try await service.createFolder(named: "X", in: stale) }
        let file = try makeTempDirectory().appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: file)
        await #expect(throws: MTPError.phoneReconnected) {
            try await service.upload(jobID: UUID(), fileURL: file, to: stale, conflict: .fail)
        }
        #expect(device.children(of: FileEntry.rootID).map(\.name) == ["DCIM"])
    }

    @Test func staleSessionRenameAndDeleteAreRefused() async throws {
        let (service, _) = try await makeService()
        let file = device.addFile("a.txt", data: Data("a".utf8))
        let stale = FolderRef(deviceID: "serial-ABC", storageID: 1, session: UUID())
        await #expect(throws: MTPError.phoneReconnected) { try await service.rename(file, in: stale, to: "b.txt") }
        await #expect(throws: MTPError.phoneReconnected) { try await service.delete(file, in: stale) }
        #expect(device.children(of: FileEntry.rootID).map(\.name) == ["a.txt"])
    }

    @Test func renameAndDeleteVerifyTheEntry() async throws {
        let (service, session) = try await makeService()
        let file = device.addFile("a.txt", data: Data("a".utf8))
        let folder = FolderRef(deviceID: "serial-ABC", storageID: 1, session: session)
        var impostor = file
        impostor.name = "someone-else.txt" // the handle now names a different item
        await #expect(throws: MTPError.notFound) { try await service.rename(impostor, in: folder, to: "b.txt") }
        await #expect(throws: MTPError.notFound) { try await service.delete(impostor, in: folder) }
        #expect(device.children(of: FileEntry.rootID).map(\.name) == ["a.txt"])
        try await service.rename(file, in: folder, to: "b.txt")
        var renamed = file
        renamed.name = "b.txt"
        try await service.delete(renamed, in: folder)
        #expect(device.children(of: FileEntry.rootID).isEmpty)
    }
}
```

Add inside `DeviceStoreTests` (`Packages/MTPKit/Tests/TetherCoreTests/DeviceStoreTests.swift`):

```swift
    @Test func sessionChangeDropsListingsAndCountsAsReconnect() async throws {
        let (store, _) = makeStore()
        await store.reloadDevices()
        await store.refresh(folder)
        #expect(store.listings[folder] != nil)
        var reconnected: [DeviceID] = []
        store.onDeviceBecameReady = { reconnected.append($0) }
        var info = try #require(store.devices.first)
        info.session = UUID()
        store.apply([info])
        #expect(store.listings.isEmpty)
        #expect(reconnected == ["p1"])
        #expect(store.session(for: "p1") == info.session)
    }
```

Update `ModelsTests.everyErrorHasAMessage` (`Packages/MTPKit/Tests/MTPKitTests/ModelsTests.swift`) to include `.phoneReconnected` in its list.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/MTPKit --filter "SessionTests|DeviceStoreTests"`
Expected: compile errors: `has no member 'session'`, `type 'MTPError' has no member 'phoneReconnected'`.

- [ ] **Step 3: Models and error**

In `Models.swift`:

1. Add `public var session: UUID?` to `DeviceInfo`. Change its init to `init(id:manufacturer:model:state:session: UUID? = nil)` and assign it.
2. Add `public let session: UUID?` to `FolderRef`. Change its init to `init(deviceID: DeviceID, storageID: UInt32, folderID: UInt32 = FileEntry.rootID, session: UUID? = nil)` and assign it. Doc comment: "The connection session this folder was listed in; nil skips the check."

In `MTPError.swift`, add the case `case phoneReconnected` (after `serviceInterrupted`) and its message:

```swift
        case .phoneReconnected:
            String(localized: "The phone was reconnected. Open the folder again and retry.")
```

- [ ] **Step 4: New rename/delete requirements**

In `MTPService.swift`, replace the two requirements:

```swift
    /// Verifies `entry` still names the same item, then renames it.
    func rename(_ entry: FileEntry, in folder: FolderRef, to newName: String) async throws
    /// Verifies `entry` still names the same item, then deletes it (folders recursively).
    func delete(_ entry: FileEntry, in folder: FolderRef) async throws
```

- [ ] **Step 5: Sessions and checks in `LocalMTPService`**

1. In `performScan()`'s `.success` branch, add `session: UUID()` to the `DeviceInfo(...)` built for `infos[device.id]`.
2. Add a helper below `worker(_:)`:

```swift
    /// Refuses a folder from an earlier connection: Android renumbers objects on reconnect.
    private func checkSession(_ folder: FolderRef) throws {
        guard let expected = folder.session else { return }
        let key = publicIDs.first { $0.value == folder.deviceID }?.key ?? folder.deviceID
        guard infos[key]?.session == expected else { throw MTPError.phoneReconnected }
    }
```

3. In `list`, `createFolder` and `upload`, resolve the worker first and then call `try checkSession(folder)` before `perform`. Example for `list`:

```swift
    public func list(_ folder: FolderRef) async throws -> [FileEntry] {
        let worker = try await worker(folder.deviceID, scanning: true)
        try checkSession(folder)
        return try await worker.perform(.interactive) {
            try $0.listFolder(storageID: folder.storageID, folderID: folder.folderID)
        }
    }
```

4. Replace `rename` and `delete`:

```swift
    public func rename(_ entry: FileEntry, in folder: FolderRef, to newName: String) async throws {
        let worker = try await worker(folder.deviceID, scanning: true)
        try checkSession(folder)
        try await worker.perform(.interactive) { device in
            try Transfers.verify(entry, on: device)
            try device.rename(objectID: entry.objectID, to: newName)
        }
    }

    public func delete(_ entry: FileEntry, in folder: FolderRef) async throws {
        let worker = try await worker(folder.deviceID, scanning: true)
        try checkSession(folder)
        try await worker.perform(.interactive) { device in
            try Transfers.verify(entry, on: device)
            try device.delete(objectID: entry.objectID)
        }
    }
```

- [ ] **Step 6: XPC**

`XPCMessages.swift`: replace the two cases:

```swift
    case rename(entry: FileEntry, folder: FolderRef, newName: String)
    case delete(entry: FileEntry, folder: FolderRef)
```

`MTPXPCEndpoint.swift` `handle`:

```swift
        case .rename(let entry, let folder, let newName):
            try await service.rename(entry, in: folder, to: newName)
            return .ok
        case .delete(let entry, let folder):
            try await service.delete(entry, in: folder)
            return .ok
```

`XPCMTPService.swift`:

```swift
    public func rename(_ entry: FileEntry, in folder: FolderRef, to newName: String) async throws {
        _ = try await send(.rename(entry: entry, folder: folder, newName: newName))
    }

    public func delete(_ entry: FileEntry, in folder: FolderRef) async throws {
        _ = try await send(.delete(entry: entry, folder: folder))
    }
```

- [ ] **Step 7: `DeviceStore`**

1. Add:

```swift
    public func session(for deviceID: DeviceID) -> UUID? {
        devices.first { $0.id == deviceID && $0.state == .ready }?.session
    }
```

2. Replace `apply(_:)`:

```swift
    public func apply(_ newDevices: [DeviceInfo]) {
        let before = Dictionary(devices.filter { $0.state == .ready }.map { ($0.id, $0.session) },
                                uniquingKeysWith: { first, _ in first })
        let now = Dictionary(newDevices.filter { $0.state == .ready }.map { ($0.id, $0.session) },
                             uniquingKeysWith: { first, _ in first })
        // Newly ready, or ready again on a new connection (handles from the old one are meaningless).
        let fresh = Set(now.keys.filter { id in
            guard let old = before[id] else { return true }
            return old != now[id]!
        })
        devices = newDevices
        storages = storages.filter { now[$0.key] != nil && !fresh.contains($0.key) }
        listings = listings.filter { key, _ in now[key.deviceID] != nil && !fresh.contains(key.deviceID) }
        for id in fresh {
            onDeviceBecameReady?(id)
            Task { await loadStorages(id) }
        }
    }
```

3. In `rename(_:in:to:)` and `delete(_:in:)`, call the new service API: `service.rename(entry, in: folder, to: newName)` and `service.delete(entry, in: folder)`.

4. Update every other call site and test double, found by grepping for `rename(objectID:` and `delete(objectID:` under `Packages/` and `Tether/`. This includes `FlakyService` in `DeviceStoreTests.swift` and the `mutationsReachTheDevice` test in `LocalMTPServiceTests.swift`, which should rename and delete through the new entry-based calls.

- [ ] **Step 8: Browser folders carry the session**

In `Tether/BrowserView.swift`:

1. Add `private var session: UUID? { model.devices.session(for: selection.deviceID) }`.
2. Build `folder` with it: `FolderRef(deviceID: selection.deviceID, storageID: selection.storageID, folderID: path.last?.objectID ?? FileEntry.rootID, session: session)`.
3. Add `.onChange(of: session) { path = [] }` after the existing `.onChange(of: folder)`. The path's handles belong to the old connection.

- [ ] **Step 9: Run tests to verify they pass**

Run: `swift test --package-path Packages/MTPKit`
Expected: all tests pass, including 4 `SessionTests` and `sessionChangeDropsListingsAndCountsAsReconnect`.

- [ ] **Step 10: Build the app**

Run: `xcodegen generate && xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Debug -derivedDataPath DerivedData build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 11: Commit**

```bash
git add -A Packages/MTPKit Tether
git commit -m "feat: connection sessions; refuse calls and edits from an older connection"
```

---

### Task 3: Thumbnails: device call, service, and `ThumbnailStore`

**Files:**
- Modify: `Packages/MTPKit/Sources/MTPKit/MTPDevice.swift`, `FakeDevice.swift`, `MTPService.swift`, `LocalMTPService.swift`, `XPC/XPCMessages.swift`, `XPC/MTPXPCEndpoint.swift`, `XPC/XPCMTPService.swift`
- Modify (test double): `FlakyService` in `DeviceStoreTests.swift`
- Create: `Packages/MTPKit/Sources/TetherCore/ItemKey.swift`, `Packages/MTPKit/Sources/TetherCore/ThumbnailStore.swift`
- Modify: `Packages/MTPKit/Sources/TetherCore/AppModel.swift`
- Modify: `MTPHelper/LibMTPDevice.swift`
- Test: `Packages/MTPKit/Tests/TetherCoreTests/ThumbnailStoreTests.swift` (new), `Packages/MTPKit/Tests/MTPKitTests/XPCTests.swift` (add)

**Interfaces:**
- Consumes: sessions and `checkSession` (Task 2), and `DeviceWorker.Priority.background` (Plan 1).
- Produces:
  - **Device call:** `MTPDevice.thumbnail(objectID: UInt32) throws -> Data?`. It returns `nil` when the phone has no thumbnail.
  - **`FakeDevice` additions:** `setThumbnail(_ data: Data, for objectID: UInt32)`, `thumbnailCalls: Int`, and `failNextThumbnail(with: MTPError)`. Thumbnail calls don't consume the general fault queue.
  - **Service call:** `MTPService.thumbnail(objectID: UInt32, in folder: FolderRef) async throws -> Data?`. It is session-checked and runs at `.background` priority.
  - **XPC:** `XPCRequest.thumbnail(objectID:folder:)` and `XPCResponse.thumbnail(Data?)`.
  - **`ItemKey`:** `public struct ItemKey: Hashable, Sendable`, built with `init(entry: FileEntry, deviceID: DeviceID)`. `fileName: String` is a SHA-256 hex of deviceID, storageID, objectID, size and modified.
  - **`ThumbnailStore`:** `@MainActor @Observable public final class ThumbnailStore` with:
    - `init(service:directory:)`
    - `static var defaultDirectory: URL?`
    - `static func wantsThumbnail(_:) -> Bool`
    - `version: Int`, observable and bumped whenever a thumbnail arrives
    - `cached(_ entry: FileEntry, deviceID: DeviceID) -> Data?`
    - `request(_ entry: FileEntry, in folder: FolderRef)`
  - **`AppModel.thumbnails: ThumbnailStore`.**

**`ThumbnailStore` rules:**
- **Which items:** only files whose extension is a common image or video type are requested.
- **Order of lookup:** memory first, then the disk file `directory/<fileName>`, then the service. A fetched thumbnail is written to disk atomically.
- **Deduplication:** a key already in flight is not requested again.
- **No thumbnail vs failure:** a `nil` reply is remembered as "no thumbnail" for this store's lifetime. A thrown error is not remembered, so the next request retries.

- [ ] **Step 1: Write the failing tests**

`Packages/MTPKit/Tests/TetherCoreTests/ThumbnailStoreTests.swift`:

```swift
import Foundation
import Testing
import MTPKit
@testable import TetherCore

@MainActor
@Suite struct ThumbnailStoreTests {
    let provider = FakeDeviceProvider()
    let device = FakeDevice(id: "p1")
    var folder: FolderRef { FolderRef(deviceID: "p1", storageID: 1) }

    private func makeStore(directory: URL? = nil) async throws -> (ThumbnailStore, LocalMTPService) {
        provider.attach(device)
        let service = LocalMTPService(provider: provider)
        _ = try await service.devices()
        return (ThumbnailStore(service: service, directory: directory), service)
    }

    @Test func fetchesOnceAndCachesInMemory() async throws {
        let photo = device.addFile("a.jpg", data: Data(count: 10))
        device.setThumbnail(Data("thumb".utf8), for: photo.objectID)
        let (store, _) = try await makeStore()
        store.request(photo, in: folder)
        store.request(photo, in: folder) // deduplicated while in flight
        try await eventually { store.cached(photo, deviceID: "p1") != nil }
        store.request(photo, in: folder)
        #expect(store.cached(photo, deviceID: "p1") == Data("thumb".utf8))
        #expect(device.thumbnailCalls == 1)
        #expect(store.version == 1)
    }

    @Test func diskCacheSurvivesANewStore() async throws {
        let photo = device.addFile("a.jpg", data: Data(count: 10))
        device.setThumbnail(Data("thumb".utf8), for: photo.objectID)
        let dir = try makeTempDirectory()
        let (first, service) = try await makeStore(directory: dir)
        first.request(photo, in: folder)
        try await eventually { first.cached(photo, deviceID: "p1") != nil }
        let second = ThumbnailStore(service: service, directory: dir)
        second.request(photo, in: folder)
        try await eventually { second.cached(photo, deviceID: "p1") != nil }
        #expect(device.thumbnailCalls == 1)
    }

    @Test func missingThumbnailIsNotRefetched() async throws {
        let photo = device.addFile("a.jpg", data: Data(count: 10)) // no thumbnail set
        let (store, _) = try await makeStore()
        store.request(photo, in: folder)
        try await eventually { device.thumbnailCalls == 1 }
        try await Task.sleep(for: .milliseconds(50))
        store.request(photo, in: folder)
        try await Task.sleep(for: .milliseconds(50))
        #expect(device.thumbnailCalls == 1)
        #expect(store.cached(photo, deviceID: "p1") == nil)
    }

    @Test func transientFailureIsRetried() async throws {
        let photo = device.addFile("a.jpg", data: Data(count: 10))
        device.setThumbnail(Data("thumb".utf8), for: photo.objectID)
        device.failNextThumbnail(with: .deviceBusy)
        let (store, _) = try await makeStore()
        store.request(photo, in: folder)
        try await eventually { device.thumbnailCalls == 1 }
        try await Task.sleep(for: .milliseconds(50))
        store.request(photo, in: folder)
        try await eventually { store.cached(photo, deviceID: "p1") != nil }
        #expect(device.thumbnailCalls == 2)
    }

    @Test func changedItemGetsNewThumbnail() async throws {
        let photo = device.addFile("a.jpg", data: Data(count: 10))
        device.setThumbnail(Data("v1".utf8), for: photo.objectID)
        let (store, _) = try await makeStore()
        store.request(photo, in: folder)
        try await eventually { store.cached(photo, deviceID: "p1") != nil }
        var edited = photo
        edited.size = 20
        edited.modified = Date(timeIntervalSince1970: 1_800_000_000)
        device.setThumbnail(Data("v2".utf8), for: photo.objectID)
        store.request(edited, in: folder)
        try await eventually { store.cached(edited, deviceID: "p1") != nil }
        #expect(store.cached(edited, deviceID: "p1") == Data("v2".utf8))
    }

    @Test func onlyImagesAndVideosWantThumbnails() {
        func entry(_ name: String, folder: Bool = false) -> FileEntry {
            FileEntry(objectID: 1, parentID: FileEntry.rootID, storageID: 1, name: name, size: 1, modified: nil, isFolder: folder)
        }
        #expect(ThumbnailStore.wantsThumbnail(entry("IMG_1.JPG")))
        #expect(ThumbnailStore.wantsThumbnail(entry("clip.mp4")))
        #expect(!ThumbnailStore.wantsThumbnail(entry("notes.txt")))
        #expect(!ThumbnailStore.wantsThumbnail(entry("Photos.jpg", folder: true)))
    }
}
```

Add inside `XPCTests`:

```swift
    @Test func thumbnailCrossesXPC() async throws {
        let photo = device.addFile("a.jpg", data: Data(count: 10))
        device.setThumbnail(Data("thumb".utf8), for: photo.objectID)
        let (client, host) = makeClient()
        _ = try await client.devices()
        let folder = FolderRef(deviceID: "p1", storageID: 1)
        #expect(try await client.thumbnail(objectID: photo.objectID, in: folder) == Data("thumb".utf8))
        let plain = device.addFile("b.txt", data: Data(count: 1))
        #expect(try await client.thumbnail(objectID: plain.objectID, in: folder) == nil)
        withExtendedLifetime(host) {}
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/MTPKit --filter "ThumbnailStoreTests|XPCTests"`
Expected: compile errors: `cannot find 'ThumbnailStore'`, `has no member 'setThumbnail'`.

- [ ] **Step 3: Device call and fake**

In `MTPDevice.swift`, add to the protocol:

```swift
    /// The phone's own thumbnail for the object (usually JPEG), or nil if it has none.
    func thumbnail(objectID: UInt32) throws -> Data?
```

In `FakeDevice.swift`, add:
- the private state `private var thumbnails: [UInt32: Data] = [:]`, `private var thumbnailCount = 0` and `private var thumbnailFault: MTPError?`
- this public API and implementation:

```swift
    public func setThumbnail(_ data: Data, for objectID: UInt32) { lock.withLock { thumbnails[objectID] = data } }
    public var thumbnailCalls: Int { lock.withLock { thumbnailCount } }
    /// The next `thumbnail` call throws `error` (separate from the general fault queue).
    public func failNextThumbnail(with error: MTPError) { lock.withLock { thumbnailFault = error } }

    public func thumbnail(objectID: UInt32) throws -> Data? {
        try lock.withLock {
            thumbnailCount += 1
            if disconnected { throw MTPError.deviceDisconnected }
            if let fault = thumbnailFault {
                thumbnailFault = nil
                throw fault
            }
            return thumbnails[objectID]
        }
    }
```

- [ ] **Step 4: Service and XPC**

`MTPService.swift`, add the requirement:

```swift
    /// The phone's thumbnail for an object in `folder`, fetched at background priority; nil if none.
    func thumbnail(objectID: UInt32, in folder: FolderRef) async throws -> Data?
```

`LocalMTPService.swift`:

```swift
    public func thumbnail(objectID: UInt32, in folder: FolderRef) async throws -> Data? {
        let worker = try await worker(folder.deviceID, scanning: true)
        try checkSession(folder)
        return try await worker.perform(.background) { try $0.thumbnail(objectID: objectID) }
    }
```

`XPCMessages.swift`:
- Add `case thumbnail(objectID: UInt32, folder: FolderRef)` to `XPCRequest`.
- Add `case thumbnail(Data?)` to `XPCResponse`.

`MTPXPCEndpoint.swift` `handle`:

```swift
        case .thumbnail(let objectID, let folder):
            return .thumbnail(try await service.thumbnail(objectID: objectID, in: folder))
```

`XPCMTPService.swift`:

```swift
    public func thumbnail(objectID: UInt32, in folder: FolderRef) async throws -> Data? {
        guard case .thumbnail(let data) = try await send(.thumbnail(objectID: objectID, folder: folder)) else {
            throw MTPError.unexpectedResponse
        }
        return data
    }
```

Add the forwarding method to `FlakyService` in `DeviceStoreTests.swift`:

```swift
    func thumbnail(objectID: UInt32, in folder: FolderRef) async throws -> Data? {
        try await base.thumbnail(objectID: objectID, in: folder)
    }
```

- [ ] **Step 5: `ItemKey.swift`**

```swift
import CryptoKit
import Foundation
import MTPKit

/// Identifies one version of one phone item for on-disk caches. A changed size or date means a new key.
public struct ItemKey: Hashable, Sendable {
    public let deviceID: DeviceID
    public let storageID: UInt32
    public let objectID: UInt32
    public let size: UInt64
    public let modified: Date?

    public init(entry: FileEntry, deviceID: DeviceID) {
        self.deviceID = deviceID
        storageID = entry.storageID
        objectID = entry.objectID
        size = entry.size
        modified = entry.modified
    }

    /// A filesystem-safe, collision-resistant name for this key.
    public var fileName: String {
        let raw = "\(deviceID)|\(storageID)|\(objectID)|\(size)|\(modified?.timeIntervalSince1970 ?? 0)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 6: `ThumbnailStore.swift`**

```swift
import Foundation
import Observation
import MTPKit

@MainActor
@Observable
public final class ThumbnailStore {
    /// Bumped whenever a thumbnail arrives; views observe it to refresh visible items.
    public private(set) var version = 0

    @ObservationIgnored private var memory: [ItemKey: Data] = [:]
    @ObservationIgnored private var missing: Set<ItemKey> = []
    @ObservationIgnored private var inFlight: Set<ItemKey> = []
    @ObservationIgnored private let service: any MTPService
    @ObservationIgnored private let directory: URL?

    public init(service: any MTPService, directory: URL? = ThumbnailStore.defaultDirectory) {
        self.service = service
        self.directory = directory
    }

    public static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("dev.tether.Tether/thumbnails", isDirectory: true)
    }

    private static let extensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "dng",
        "mp4", "mov", "m4v", "3gp", "mkv", "webm",
    ]

    public static func wantsThumbnail(_ entry: FileEntry) -> Bool {
        !entry.isFolder && extensions.contains((entry.name as NSString).pathExtension.lowercased())
    }

    public func cached(_ entry: FileEntry, deviceID: DeviceID) -> Data? {
        memory[ItemKey(entry: entry, deviceID: deviceID)]
    }

    /// Starts loading the thumbnail if it isn't cached, missing, or already loading. Safe to call often.
    public func request(_ entry: FileEntry, in folder: FolderRef) {
        guard Self.wantsThumbnail(entry) else { return }
        let key = ItemKey(entry: entry, deviceID: folder.deviceID)
        guard memory[key] == nil, !missing.contains(key), !inFlight.contains(key) else { return }
        inFlight.insert(key)
        let file = directory?.appendingPathComponent(key.fileName)
        let service = self.service
        Task {
            defer { inFlight.remove(key) }
            if let file, let data = try? Data(contentsOf: file) {
                store(data, for: key)
                return
            }
            do {
                guard let data = try await service.thumbnail(objectID: entry.objectID, in: folder) else {
                    missing.insert(key) // the phone has none; don't ask again
                    return
                }
                if let file {
                    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                             withIntermediateDirectories: true)
                    try? data.write(to: file, options: .atomic)
                }
                store(data, for: key)
            } catch {
                // Busy / disconnected: leave it unmarked so a later request retries.
            }
        }
    }

    private func store(_ data: Data, for key: ItemKey) {
        memory[key] = data
        version += 1
    }
}
```

- [ ] **Step 7: `AppModel` owns the store**

In `AppModel.swift`, add `public let thumbnails: ThumbnailStore`. Initialize it in `init` after `transfers`: `thumbnails = ThumbnailStore(service: service)`.

- [ ] **Step 8: Run tests to verify they pass**

Run: `swift test --package-path Packages/MTPKit`
Expected: all tests pass, including 6 `ThumbnailStoreTests` and `thumbnailCrossesXPC`.

- [ ] **Step 9: `LibMTPDevice.thumbnail`**

In `MTPHelper/LibMTPDevice.swift`:

```swift
    func thumbnail(objectID: UInt32) throws -> Data? {
        let h = try requireHandle()
        LIBMTP_Clear_Errorstack(h)
        var data: UnsafeMutablePointer<UInt8>?
        var size: UInt32 = 0
        let rc = LIBMTP_Get_Thumbnail(h, objectID, &data, &size)
        defer { if let data { free(data) } }
        guard rc == 0, let data, size > 0 else {
            if rc != 0, LIBMTP_Get_Errorstack(h) != nil, case .deviceDisconnected = lastError(h) {
                throw MTPError.deviceDisconnected
            }
            LIBMTP_Clear_Errorstack(h)
            return nil // no thumbnail for this object
        }
        return Data(bytes: data, count: Int(size))
    }
```

- [ ] **Step 10: Build the app**

Run: `xcodegen generate && xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Debug -derivedDataPath DerivedData build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 11: Commit**

```bash
git add -A Packages/MTPKit MTPHelper
git commit -m "feat: phone thumbnails with memory and disk cache"
```

---

### Task 4: `PreviewCache` for Quick Look

**Files:**
- Create: `Packages/MTPKit/Sources/TetherCore/PreviewCache.swift`
- Modify: `Packages/MTPKit/Sources/TetherCore/AppModel.swift`
- Test: `Packages/MTPKit/Tests/TetherCoreTests/PreviewCacheTests.swift`

**Interfaces:**
- Consumes: `ItemKey` (Task 3) and `MTPService.download(jobID:entry:deviceID:into:)` (Plan 1).
- Produces:
  - `@MainActor public final class PreviewCache`, with:
    - `init(service: any MTPService, directory: URL = PreviewCache.defaultDirectory)`
    - `static var defaultDirectory: URL` (`~/Library/Caches/dev.tether.Tether/preview`)
    - `func file(for entry: FileEntry, deviceID: DeviceID) async throws -> URL`
    - `func clear()`
    - `nonisolated static func clear(directory: URL = defaultDirectory)`
  - `AppModel.previews: PreviewCache`

**Rules:**
- **Where files go:** each item version is downloaded into its own directory, `directory/<ItemKey.fileName>/`, so same-named files never collide.
- **Reuse:** an existing downloaded file is reused while it still exists on disk.
- **Concurrency:** concurrent requests for one key share one download.
- **Errors:** errors propagate to the caller.
- **Not part of the queue:** preview downloads don't go through `TransferQueue`, so they don't appear in Transfers.

- [ ] **Step 1: Write the failing tests**

`Packages/MTPKit/Tests/TetherCoreTests/PreviewCacheTests.swift`:

```swift
import Foundation
import Testing
import MTPKit
@testable import TetherCore

@MainActor
@Suite struct PreviewCacheTests {
    let provider = FakeDeviceProvider()
    let device = FakeDevice(id: "p1", chunkSize: 1024, chunkDelay: 0.002)

    private func makeCache() async throws -> (PreviewCache, URL) {
        provider.attach(device)
        let service = LocalMTPService(provider: provider)
        _ = try await service.devices()
        let dir = try makeTempDirectory()
        return (PreviewCache(service: service, directory: dir), dir)
    }

    @Test func downloadsOnceAndReuses() async throws {
        let file = device.addFile("a.txt", data: Data("hello".utf8))
        let (cache, _) = try await makeCache()
        async let first = cache.file(for: file, deviceID: "p1")
        async let second = cache.file(for: file, deviceID: "p1") // shares the in-flight download
        let (a, b) = try await (first, second)
        #expect(a == b)
        #expect(a.lastPathComponent == "a.txt")
        #expect(try Data(contentsOf: a) == Data("hello".utf8))
        let again = try await cache.file(for: file, deviceID: "p1")
        #expect(again == a)
        #expect(try FileManager.default.contentsOfDirectory(atPath: a.deletingLastPathComponent().path) == ["a.txt"])
    }

    @Test func sameNameDifferentItemsDoNotCollide() async throws {
        let one = device.addFolder("One")
        let two = device.addFolder("Two")
        let a = device.addFile("IMG.jpg", data: Data("first".utf8), in: one.objectID)
        let b = device.addFile("IMG.jpg", data: Data("second".utf8), in: two.objectID)
        let (cache, _) = try await makeCache()
        let urlA = try await cache.file(for: a, deviceID: "p1")
        let urlB = try await cache.file(for: b, deviceID: "p1")
        #expect(urlA != urlB)
        #expect(try Data(contentsOf: urlA) == Data("first".utf8))
        #expect(try Data(contentsOf: urlB) == Data("second".utf8))
    }

    @Test func changedItemIsDownloadedAgain() async throws {
        let file = device.addFile("a.txt", data: Data("v1".utf8))
        let (cache, _) = try await makeCache()
        let first = try await cache.file(for: file, deviceID: "p1")
        var edited = file
        edited.modified = Date(timeIntervalSince1970: 1_800_000_000) // verification doesn't compare dates
        let second = try await cache.file(for: edited, deviceID: "p1")
        #expect(first != second)
    }

    @Test func clearRemovesEverything() async throws {
        let file = device.addFile("a.txt", data: Data("x".utf8))
        let (cache, dir) = try await makeCache()
        let url = try await cache.file(for: file, deviceID: "p1")
        cache.clear()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        let again = try await cache.file(for: file, deviceID: "p1") // works after clearing
        #expect(FileManager.default.fileExists(atPath: again.path))
    }

    @Test func errorsPropagate() async throws {
        let file = device.addFile("a.txt", data: Data("x".utf8))
        let (cache, _) = try await makeCache()
        var gone = file
        gone.name = "missing.txt"
        await #expect(throws: MTPError.notFound) { try await cache.file(for: gone, deviceID: "p1") }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/MTPKit --filter PreviewCacheTests`
Expected: compile error `cannot find 'PreviewCache' in scope`.

- [ ] **Step 3: Implement `PreviewCache.swift`**

```swift
import Foundation
import MTPKit

/// Downloads phone files for Quick Look into a private cache, one directory per item version.
@MainActor
public final class PreviewCache {
    private let service: any MTPService
    private let directory: URL
    private var ready: [ItemKey: URL] = [:]
    private var inFlight: [ItemKey: Task<URL, Error>] = [:]

    public init(service: any MTPService, directory: URL = PreviewCache.defaultDirectory) {
        self.service = service
        self.directory = directory
    }

    public nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.tether.Tether/preview", isDirectory: true)
    }

    public func file(for entry: FileEntry, deviceID: DeviceID) async throws -> URL {
        let key = ItemKey(entry: entry, deviceID: deviceID)
        if let url = ready[key], FileManager.default.fileExists(atPath: url.path) { return url }
        if let task = inFlight[key] { return try await task.value }

        let folder = directory.appendingPathComponent(key.fileName, isDirectory: true)
        let service = self.service
        let task = Task { () throws -> URL in
            try? FileManager.default.removeItem(at: folder) // a leftover from an interrupted download
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return try await service.download(jobID: UUID(), entry: entry, deviceID: deviceID, into: folder)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let url = try await task.value
        ready[key] = url
        return url
    }

    public func clear() {
        ready.removeAll()
        Self.clear(directory: directory)
    }

    /// Removes the cache directory; safe from any thread (used on quit).
    public nonisolated static func clear(directory: URL = defaultDirectory) {
        try? FileManager.default.removeItem(at: directory)
    }
}
```

- [ ] **Step 4: `AppModel` owns the cache**

In `AppModel.swift`, add `public let previews: PreviewCache`. Initialize it in `init` after `thumbnails`: `previews = PreviewCache(service: service)`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path Packages/MTPKit`
Expected: all tests pass, including 5 `PreviewCacheTests`.

- [ ] **Step 6: Commit**

```bash
git add -A Packages/MTPKit
git commit -m "feat(TetherCore): preview cache for Quick Look"
```

---

### Task 5: Icon view with thumbnails, view switching, rename sheet

**Files:**
- Modify: `Packages/MTPKit/Sources/TetherCore/AppSettings.swift`
- Create: `Tether/FileGridView.swift`, `Tether/RenameSheet.swift`
- Modify: `Tether/BrowserView.swift`, `Tether/BrowserCommands.swift`

**Interfaces:**
- Consumes:
  - `ThumbnailStore` (`version`, `cached`, `request`) from Task 3
  - `FileTableActions` and `FileTableView` (Plan 2a, as fixed)
  - `BrowserView` helpers (`commitRename`, `renameContext`, `isEditingName`, `newFolder`)
- Produces:
  - `public enum BrowserViewMode: String, CaseIterable, Sendable { case icons, list }` and `SettingsKey.viewMode = "viewMode"`
  - `FileGridView(entries:selection:folderKey:thumbnailVersion:thumbnail:requestThumbnail:actions:)`
  - `RenameSheet(entry:onCommit:)`
  - a View menu "as Icons" (⌘1) / "as List" (⌘2), plus a segmented toolbar control

**Behavior:**
- **What the grid shows:** each item is a 64-pt thumbnail (when the phone has one) or the file-type icon, with its name below on two lines. Folders come first, then names in Finder order.
- **Interaction:**
  - Selection is tracked by object ID through the same binding as the list.
  - Double-click opens, and Return renames the single selected item.
- **Same as the list:**
  - the right-click menu (Open, Download, Rename, Delete…, New Folder)
  - drag-out file promises
  - drop-in uploads
- **Rename in icon view:** uses a sheet (`RenameSheet`) instead of editing in place. The menu's Delete and Rename are disabled while the sheet is open.
- **Thumbnail refresh:** when `ThumbnailStore.version` changes, the visible items' images are refreshed in place, with no reload, so selection is kept.

No unit tests: this is AppKit glue over tested stores. Verify with a build and a launch, and the manual checklist in Step 7.

- [ ] **Step 1: View mode setting**

In `Packages/MTPKit/Sources/TetherCore/AppSettings.swift`:
1. Add `public static let viewMode = "viewMode"` to `SettingsKey`.
2. Add at the end of the file:

```swift
public enum BrowserViewMode: String, CaseIterable, Sendable {
    case icons, list
}
```

Run: `swift test --package-path Packages/MTPKit`
Expected: all tests pass. Nothing else changes in the package.

- [ ] **Step 2: Create `Tether/FileGridView.swift`**

```swift
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MTPKit

/// Finder-style icon view backed by NSCollectionView, sharing the list's actions.
struct FileGridView: NSViewRepresentable {
    var entries: [FileEntry]
    @Binding var selection: Set<UInt32>
    var folderKey: FolderRef
    /// Changes whenever new thumbnails arrive.
    var thumbnailVersion: Int
    var thumbnail: (FileEntry) -> NSImage?
    var requestThumbnail: (FileEntry) -> Void
    var actions: FileTableActions

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 104, height: 112)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let grid = FileGrid()
        grid.collectionViewLayout = layout
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.backgroundColors = [.clear]
        grid.register(FileGridItem.self, forItemWithIdentifier: FileGridItem.identifier)
        grid.dataSource = context.coordinator
        grid.delegate = context.coordinator
        grid.registerForDraggedTypes([.fileURL])
        grid.setDraggingSourceOperationMask(.copy, forLocal: false)
        let coordinator = context.coordinator
        grid.onDoubleClick = { [weak coordinator] path in coordinator?.open(at: path) }
        grid.onReturn = { [weak coordinator] in coordinator?.returnPressed() }
        let menu = NSMenu()
        menu.delegate = coordinator
        grid.menu = menu
        coordinator.grid = grid

        let scroll = NSScrollView()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.folderChanged(to: folderKey)
        coordinator.show(entries)
        coordinator.syncSelectionFromParent()
        coordinator.refreshThumbnails(version: thumbnailVersion)
    }

    /// Double-click and Return handling plus the clicked item for the context menu.
    final class FileGrid: NSCollectionView {
        var onDoubleClick: (@MainActor (IndexPath) -> Void)?
        var onReturn: (@MainActor () -> Void)?
        private(set) var menuIndexPath: IndexPath?

        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            if event.clickCount == 2, let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
                onDoubleClick?(path)
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            menuIndexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil))
            return super.menu(for: event)
        }

        override func keyDown(with event: NSEvent) {
            let plain = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function]).isEmpty
            if plain, event.keyCode == 36 || event.keyCode == 76, let onReturn {
                onReturn()
                return
            }
            super.keyDown(with: event)
        }
    }

    final class FileGridItem: NSCollectionViewItem {
        static let identifier = NSUserInterfaceItemIdentifier("FileGridItem")

        override func loadView() {
            let root = NSView()
            root.wantsLayer = true
            let image = NSImageView()
            image.imageScaling = .scaleProportionallyUpOrDown
            image.translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(wrappingLabelWithString: "")
            label.alignment = .center
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byTruncatingMiddle
            label.font = .systemFont(ofSize: 12)
            label.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(image)
            root.addSubview(label)
            NSLayoutConstraint.activate([
                image.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
                image.centerXAnchor.constraint(equalTo: root.centerXAnchor),
                image.widthAnchor.constraint(equalToConstant: 64),
                image.heightAnchor.constraint(equalToConstant: 64),
                label.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 4),
                label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -2),
            ])
            view = root
            imageView = image
            textField = label
        }

        override var isSelected: Bool { didSet { updateHighlight() } }
        override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateHighlight() } }

        private func updateHighlight() {
            let on = isSelected || highlightState == .forSelection
            view.layer?.cornerRadius = 8
            view.layer?.backgroundColor = on
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.3).cgColor : nil
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSMenuDelegate {
        var parent: FileGridView
        weak var grid: NSCollectionView?
        private var rows: [FileEntry] = []
        private var folderKey: FolderRef?
        private var isApplyingSelection = false
        private var thumbnailVersion = -1
        private var menuTargets: [FileEntry] = []

        init(parent: FileGridView) { self.parent = parent }

        // MARK: Data

        func folderChanged(to key: FolderRef) {
            guard key != folderKey else { return }
            folderKey = key
            grid?.scroll(.zero)
        }

        func show(_ entries: [FileEntry]) {
            let sorted = entries.sorted { a, b in
                if a.isFolder != b.isFolder { return a.isFolder }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            guard sorted != rows else { return }
            rows = sorted
            isApplyingSelection = true
            grid?.reloadData()
            isApplyingSelection = false
            applySelection()
        }

        func refreshThumbnails(version: Int) {
            guard version != thumbnailVersion, let grid else { return }
            thumbnailVersion = version
            for case let item as FileGridItem in grid.visibleItems() {
                guard let path = grid.indexPath(for: item), rows.indices.contains(path.item) else { continue }
                item.imageView?.image = image(for: rows[path.item])
            }
        }

        // MARK: Selection (by object ID)

        private var selectedIDs: Set<UInt32> {
            Set((grid?.selectionIndexPaths ?? []).compactMap { rows.indices.contains($0.item) ? rows[$0.item].objectID : nil })
        }

        private var selectedEntries: [FileEntry] {
            (grid?.selectionIndexPaths ?? []).sorted().compactMap { rows.indices.contains($0.item) ? rows[$0.item] : nil }
        }

        private func applySelection() {
            guard let grid else { return }
            let paths = Set(rows.indices.filter { parent.selection.contains(rows[$0].objectID) }
                .map { IndexPath(item: $0, section: 0) })
            isApplyingSelection = true
            grid.selectionIndexPaths = paths
            isApplyingSelection = false
        }

        func syncSelectionFromParent() {
            if selectedIDs != parent.selection { applySelection() }
        }

        private func selectionChanged() {
            guard !isApplyingSelection else { return }
            let ids = selectedIDs
            if ids != parent.selection { parent.selection = ids }
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            selectionChanged()
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            selectionChanged()
        }

        // MARK: Items

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }

        func collectionView(_ collectionView: NSCollectionView,
                            itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: FileGridItem.identifier, for: indexPath)
            let entry = rows[indexPath.item]
            item.textField?.stringValue = entry.name
            item.imageView?.image = image(for: entry)
            parent.requestThumbnail(entry)
            return item
        }

        private func image(for entry: FileEntry) -> NSImage {
            if let thumb = parent.thumbnail(entry) { return thumb }
            let type: UTType = entry.isFolder
                ? .folder
                : UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
            return NSWorkspace.shared.icon(for: type)
        }

        func open(at path: IndexPath) {
            guard rows.indices.contains(path.item) else { return }
            parent.actions.open(rows[path.item])
        }

        func returnPressed() {
            let selected = selectedEntries
            if selected.count == 1 { parent.actions.requestRename(selected[0]) }
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let grid = grid as? FileGrid else { return }
            if let path = grid.menuIndexPath, rows.indices.contains(path.item) {
                if !grid.selectionIndexPaths.contains(path) {
                    grid.selectionIndexPaths = [path] // Finder: right-click selects
                    selectionChanged()
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

        // MARK: Drag out / drop in

        func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>,
                            with event: NSEvent) -> Bool { true }

        func collectionView(_ collectionView: NSCollectionView,
                            pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            rows.indices.contains(indexPath.item) ? parent.actions.makePromise(rows[indexPath.item]) : nil
        }

        func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                            proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                            dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>)
            -> NSDragOperation {
            if (draggingInfo.draggingSource as? NSCollectionView) === collectionView { return [] }
            guard draggingInfo.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                                options: [.urlReadingFileURLsOnly: true]) else { return [] }
            proposedDropOperation.pointee = .before // the whole folder is the target
            return .copy
        }

        func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                            indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
            guard let urls = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  !urls.isEmpty else { return false }
            parent.actions.dropFiles(urls, collectionView.window)
            return true
        }
    }
}
```

- [ ] **Step 3: Create `Tether/RenameSheet.swift`**

```swift
import SwiftUI
import MTPKit

/// Rename for the icon view (the list renames in place).
struct RenameSheet: View {
    let entry: FileEntry
    let onCommit: (String) -> Void
    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(entry: FileEntry, onCommit: @escaping (String) -> Void) {
        self.entry = entry
        self.onCommit = onCommit
        _name = State(initialValue: entry.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename “\(entry.name)”").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func commit() {
        onCommit(name)
        dismiss()
    }
}
```

- [ ] **Step 4: Switch views in `Tether/BrowserView.swift`**

1. Add state:

```swift
    @AppStorage(SettingsKey.viewMode) private var viewMode = BrowserViewMode.list
    @State private var renamingEntry: FileEntry?
```

2. Replace the `FileTableView(...)` expression at the top of `body` with a view-mode switch. Keep all existing modifiers attached after it:

```swift
        Group {
            switch viewMode {
            case .icons:
                FileGridView(entries: visibleEntries, selection: $selectedIDs, folderKey: folder,
                             thumbnailVersion: model.thumbnails.version,
                             thumbnail: { entry in
                                 model.thumbnails.cached(entry, deviceID: selection.deviceID).flatMap(NSImage.init(data:))
                             },
                             requestThumbnail: { model.thumbnails.request($0, in: folder) },
                             actions: tableActions)
            case .list:
                FileTableView(entries: visibleEntries, selection: $selectedIDs, renameRequest: renameRequest,
                              folderKey: folder, actions: tableActions)
            }
        }
```

3. Add a toolbar item at the start of the `.toolbar` content, after the Back item:

```swift
                ToolbarItem {
                    Picker("View", selection: $viewMode) {
                        Label("Icons", systemImage: "square.grid.2x2").tag(BrowserViewMode.icons)
                        Label("List", systemImage: "list.bullet").tag(BrowserViewMode.list)
                    }
                    .pickerStyle(.segmented)
                    .help("Show items as icons or as a list")
                }
```

4. Add the rename sheet and the editing flag, after the `.alert(...)` modifier:

```swift
            .sheet(item: $renamingEntry) { entry in
                RenameSheet(entry: entry) { commitRename(entry, $0) }
            }
            .onChange(of: renamingEntry) { isEditingName = renamingEntry != nil }
```

5. Route renames by view mode. Add:

```swift
    private func beginRename(_ entry: FileEntry) {
        switch viewMode {
        case .list:
            renameRequest = entry.objectID
        case .icons:
            renameContext = (folder, allEntries)
            renamingEntry = entry
        }
    }
```

Then:
- In `tableActions`, set `requestRename: beginRename`.
- In `menuActions`, change the rename action to `{ beginRename(selected[0]) }`.
- In `newFolder()`, after `selectedIDs = [created.objectID]`, replace `renameRequest = created.objectID` with `beginRename(created)`.

- [ ] **Step 5: ⌘1 / ⌘2 in `Tether/BrowserCommands.swift`**

1. Add `@AppStorage(SettingsKey.viewMode) private var viewMode = BrowserViewMode.list` to `BrowserCommands`.
2. At the top of the `CommandGroup(after: .sidebar)` block, before Refresh, add:

```swift
            Button("as Icons") { viewMode = .icons }
                .keyboardShortcut("1")
            Button("as List") { viewMode = .list }
                .keyboardShortcut("2")
            Divider()
```

- [ ] **Step 6: Generate, build and launch**

Run: `xcodegen generate && xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Debug -derivedDataPath DerivedData build 2>&1 | grep -E "error:|warning: .*Tether/|BUILD"`
Expected: `** BUILD SUCCEEDED **`, with no warnings from `Tether/`.

Run: `DerivedData/Build/Products/Debug/Tether.app/Contents/MacOS/Tether -UseFakeDevices YES & PID=$!; sleep 4; kill -0 $PID && echo alive; kill $PID`
Expected: `alive`

- [ ] **Step 7: Commit**

```bash
git add -A Packages/MTPKit Tether
git commit -m "feat(app): icon view with phone thumbnails, ⌘1/⌘2 view switching, rename sheet"
```

**Manual checklist** (for the human; the demo phone's photos have no thumbnails, so check thumbnails on a real phone):
1. ⌘1 shows icons and ⌘2 shows the list. The segmented control follows, and the choice is remembered after relaunch.
2. In icon view:
   - Double-clicking a folder opens it.
   - Right-click offers the same menu as the list.
   - Return opens the rename sheet, and renaming works.
   - Drag to Finder and drop from Finder both work.
3. With a real phone in DCIM/Camera, thumbnails fill in progressively, and scrolling stays smooth.

---

### Task 6: Quick Look (Space / ⌘Y)

**Files:**
- Create: `Tether/QuickLookController.swift`
- Modify: `Tether/FileTableView.swift` (`FileTableActions.quickLook`, Space key, preview-panel control)
- Modify: `Tether/FileGridView.swift` (Space key, preview-panel control)
- Modify: `Tether/BrowserView.swift`, `Tether/BrowserCommands.swift`, `Tether/TetherApp.swift`

**Interfaces:**
- Consumes: `PreviewCache` and `AppModel.previews` (Task 4), and the list and grid (Plan 2a / Task 5).
- Produces:
  - `@MainActor final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate`, with:
    - `static let shared`
    - `toggle(_ entries: [FileEntry], deviceID: DeviceID, cache: PreviewCache, onError: @escaping @MainActor (MTPError) -> Void)`
    - `attach(_ panel: QLPreviewPanel)` and `detach(_ panel: QLPreviewPanel)`
  - `FileTableActions.quickLook: ([FileEntry]) -> Void`
  - `BrowserActions.quickLook: (() -> Void)?`, a File menu item "Quick Look" bound to ⌘Y

**Behavior:**
- **Opening:**
  - Space in the list or grid toggles Quick Look for the selected files. Folders are ignored.
  - Double-clicking a file opens Quick Look; double-clicking a folder still opens the folder.
- **Loading:** files are downloaded through `PreviewCache`, and the panel opens once they are ready. A newer toggle supersedes a slower earlier one.
- **Closing:** if the panel is already visible, Space closes it.
- **Errors:** a download error is shown in the browser's alert.
- **Cleanup:** the preview cache directory is removed when the app quits.

No unit tests: this is AppKit glue over the tested `PreviewCache`. Verify with a build, a launch and the manual checklist.

- [ ] **Step 1: Create `Tether/QuickLookController.swift`**

```swift
import AppKit
import Quartz
import MTPKit
import TetherCore

/// Feeds QLPreviewPanel with phone files downloaded into the preview cache.
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private var urls: [URL] = []
    private var latestRequest = 0

    /// Shows the selected files (folders are skipped), or closes the panel if it's open.
    func toggle(_ entries: [FileEntry], deviceID: DeviceID, cache: PreviewCache,
                onError: @escaping @MainActor (MTPError) -> Void) {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
            return
        }
        let files = entries.filter { !$0.isFolder }
        guard !files.isEmpty else { return }
        latestRequest += 1
        let request = latestRequest
        Task {
            var ready: [URL] = []
            for entry in files {
                do {
                    ready.append(try await cache.file(for: entry, deviceID: deviceID))
                } catch {
                    if request == latestRequest { onError(MTPError.from(error)) }
                    return
                }
            }
            guard request == latestRequest, let panel = QLPreviewPanel.shared() else { return }
            urls = ready
            attach(panel)
            panel.reloadData()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func attach(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    func detach(_ panel: QLPreviewPanel) {
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
    }

    // QLPreviewPanel calls these on the main thread.
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls.indices.contains(index) ? urls[index] as NSURL : nil }
    }
}
```

- [ ] **Step 2: List: Space, panel control, action**

In `Tether/FileTableView.swift`:

1. Add `var quickLook: ([FileEntry]) -> Void` to `FileTableActions`, after `newFolder`.

2. In `final class FileTable`:
   - Add `var onSpace: (@MainActor () -> Void)?`.
   - Inside `keyDown`, after the Return check and before `super.keyDown`, add:

```swift
            if plain, event.keyCode == 49, let onSpace {
                onSpace()
                return
            }
```

   - Add these overrides to the class:

```swift
        override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
        override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLookController.shared.attach(panel) }
        override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLookController.shared.detach(panel) }
```

   - Add `import Quartz` at the top of the file.

3. In `makeNSView`, next to `table.onReturn = …`, add:

```swift
        table.onSpace = { [weak coordinator = context.coordinator] in coordinator?.spacePressed() }
```

4. In the `Coordinator`, add:

```swift
        func spacePressed() {
            guard editingID == nil else { return }
            parent.actions.quickLook(selectedEntries)
        }
```

- [ ] **Step 3: Grid: Space and panel control**

In `Tether/FileGridView.swift`:

1. Add `import Quartz`.
2. In `final class FileGrid`:
   - Add `var onSpace: (@MainActor () -> Void)?`.
   - Add the Space branch to `keyDown`, the same as the list's.
   - Add the same three `…PreviewPanelControl` overrides.
3. In `makeNSView`, add `grid.onSpace = { [weak coordinator] in coordinator?.spacePressed() }`.
4. In its `Coordinator`, add:

```swift
        func spacePressed() { parent.actions.quickLook(selectedEntries) }
```

- [ ] **Step 4: Wire it in `Tether/BrowserView.swift`**

1. Add:

```swift
    private func quickLook(_ entries: [FileEntry]) {
        QuickLookController.shared.toggle(entries, deviceID: selection.deviceID, cache: model.previews) { error in
            problem = error.localizedDescription
        }
    }
```

2. Change `open(_:)` so files open in Quick Look:

```swift
    private func open(_ entry: FileEntry) {
        if entry.isFolder { path.append(entry) } else { quickLook([entry]) }
    }
```

3. In `tableActions`, add `quickLook: quickLook` after `newFolder: newFolder`.

4. In `menuActions`:
   - Add `let quickLookAction: (() -> Void)? = selected.contains { !$0.isFolder } && !editing ? { quickLook(selected) } : nil`.
   - Pass `quickLook: quickLookAction` to `BrowserActions(...)`.

- [ ] **Step 5: Menu item in `Tether/BrowserCommands.swift`**

1. Add `var quickLook: (() -> Void)?` to `BrowserActions`, after `delete`.
2. In the File group, after the Open button, add:

```swift
            Button("Quick Look") { actions?.quickLook?() }
                .keyboardShortcut("y")
                .disabled(actions?.quickLook == nil)
```

- [ ] **Step 6: Clear the preview cache on quit, in `Tether/TetherApp.swift`**

Add an initializer to `TetherApp`:

```swift
    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { _ in
            PreviewCache.clear()
        }
    }
```

- [ ] **Step 7: Generate, build and launch**

Run: `xcodegen generate && xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Debug -derivedDataPath DerivedData build 2>&1 | grep -E "error:|warning: .*Tether/|BUILD"`
Expected: `** BUILD SUCCEEDED **`, with no warnings from `Tether/`.

Run: `DerivedData/Build/Products/Debug/Tether.app/Contents/MacOS/Tether -UseFakeDevices YES & PID=$!; sleep 4; kill -0 $PID && echo alive; kill $PID`
Expected: `alive`

- [ ] **Step 8: Commit**

```bash
git add -A Tether
git commit -m "feat(app): Quick Look for phone files (Space, ⌘Y, double-click)"
```

**Manual checklist** (for the human):
1. With fake phones, select `notes.txt` and press Space. Quick Look shows "Hello from Tether". Space again closes it.
2. Select two files and press Space. Quick Look pages between them.
3. Double-clicking a file opens Quick Look, and double-clicking a folder opens the folder.
4. ⌘Y does the same as Space. Space while renaming types a space.
5. Quit Tether. `~/Library/Caches/dev.tether.Tether/preview` is gone.
6. On a real phone, preview a photo and a video.

---

## Spec coverage (Plan 2b)

| Spec / follow-up | Task |
|---|---|
| Follow-up: single-object pre-download check; restore `.partial` fault coverage | 1 |
| Follow-up: per-connection generation (missed fast replug, retry race) | 2 (sessions on `DeviceInfo` / `FolderRef`, refused calls, verified rename/delete) |
| §3: ThumbnailService: lazy, lowest priority, memory + disk cache keyed by device + object + version | 3 |
| §4: Quick Look: download to a temp cache, then `QLPreviewPanel`; cache cleared on quit | 4, 6 |
| §5: icon grid with thumbnails + sortable list; ⌘1/⌘2 | 5 |
| §5: Space Quick Look | 6 |
| §4 "shows progress for large files" in Quick Look | Not covered (the panel opens when the file is ready); noted for 2c |
| §5: empty/error states, Image Capture, String Catalog, VoiceOver; §6 diagnostics; §7 UI tests | Plan 2c |
