# Tether — Design Spec

**Date:** 2026-10-01
**Status:** Draft for review

## 1. Purpose

Tether is a free, open-source macOS app for transferring files between a Mac and
Android phones over USB (MTP). It replaces Google's outdated Android File Transfer
with a native-feeling, reliable app.

- **Audience:** public. Distributed as a Developer ID–signed, notarized DMG via
  GitHub Releases, with Sparkle auto-updates. Not on the Mac App Store.
- **Success criteria:**
  - Works with stock Android phones without enabling developer options (MTP, not ADB).
  - Transfers files larger than 4 GB.
  - Unplugging a phone, a locked phone, or a libmtp crash never freezes or kills the app window.
  - Looks and behaves like a first-party Mac app: Liquid Glass on macOS 26+,
    standard keyboard shortcuts, Finder-style navigation.
  - English and Russian UI.

### Non-goals (v1)

- Finder sidebar integration (File Provider / mounting as a volume).
- ADB transport (possible later as an optional "fast mode").
- Device-wide search (MTP has no efficient search).
- Mac App Store distribution.
- Sync / backup features.

## 2. Platform & tooling

| Item | Choice |
|---|---|
| Minimum macOS | 15.0. Liquid Glass styling on 26+ via system components; standard styling on 15. |
| Language | Swift 6 (strict concurrency), SwiftUI with AppKit where needed |
| Build | Xcode 27, one Xcode project + local Swift package `MTPKit` |
| Architectures | Universal (arm64 + x86_64) |
| Native deps | libusb 1.0.x, libmtp 1.1.x, built from source as universal dylibs by a script in the repo |
| Swift deps | Sparkle (SPM) |
| App license | MIT. libmtp/libusb (LGPL-2.1) are dynamically linked and bundled, with their license texts and source links included in the app's About/Acknowledgements |
| Bundle ID | `dev.tether.Tether` (can be changed before the first public release) |

## 3. Architecture

```
┌─────────────── Tether.app (SwiftUI) ───────────────────┐
│  Window UI ── DeviceStore ── TransferQueue ── Thumbs   │
│                     │  (typed async Swift API)         │
└─────────────────────┼──────────────────────────────────┘
                      │ XPC (NSXPCConnection)
┌─────────────────────┼──────── MTPHelper.xpc ───────────┐
│  DeviceRegistry ── one worker thread per device        │
│  MTPDevice protocol ← LibMTPDevice                     │
│  libmtp.dylib + libusb.dylib (bundled)                 │
└────────────────────────────────────────────────────────┘
```

### Components

- **MTPKit (Swift package, shared by app and helper)**
  - Value types: `DeviceInfo` (id, manufacturer, model, serial), `StorageInfo`
    (id, description, capacity, free space), `FileEntry` (objectID, parentID,
    storageID, name, size `UInt64`, modified date, kind, hasThumbnail).
  - `MTPServiceProtocol`: the XPC interface (list devices, list folder, download,
    upload, delete, rename, create folder, get thumbnail, cancel).
  - Progress/event callback protocol for helper → app messages (device
    attached/detached, transfer progress).
  - `MTPError`: typed errors (deviceDisconnected, deviceLocked, deviceBusy,
    claimedByOtherProcess, storageFull, nameConflict, timeout, cancelled,
    underlying(code, message)).
  - `MTPDevice` protocol: the per-device operations. Implemented by
    `LibMTPDevice` (helper) and `FakeDevice` (tests, previews).

- **MTPHelper.xpc** (embedded XPC service, single instance)
  - Owns libmtp. Detects plug/unplug and notifies the app.
  - `DeviceRegistry`: one dedicated worker thread per connected device; all
    libmtp calls for a device run on that thread.
  - Each device has a priority queue: interactive requests (list folder,
    rename, delete, create folder) run before queued transfers and thumbnails, but never
    interrupt a transfer already in progress.

- **DeviceStore (app)**: `@Observable` list of devices and storages; per-folder
  listing cache; owns the XPC connection; on connection interruption,
  relaunches the helper and re-enumerates devices.

- **TransferQueue (app)**: tracks jobs (state, bytes done/total, error).
  Serial per device, parallel across devices. Supports cancel and retry.

- **ThumbnailService (app)**: lazy thumbnail fetches at lowest priority, only
  when the device is idle; memory + on-disk cache keyed by device serial +
  objectID + modified date.

## 4. Data flow

**Key constraint:** an Android MTP responder handles one operation at a time,
and libmtp transfers a file in one blocking call. While a large file copies,
that device can't answer anything else.

### Browsing
- MTP has no paths: folders are listed by (storageID, parent objectID).
- Listings are cached per folder. A cached folder renders instantly, even during
  a transfer, marked "Updating…" until a fresh listing arrives.
- Cache refreshes on folder revisit, ⌘R, and after the app's own mutations.
  Device-side change events are not relied upon.

### Download (phone → Mac)
- Drag to Finder uses file promises (`NSFilePromiseProvider`); the download
  starts when Finder asks for the file.
- Writes to `<name>.partial` in the destination folder, then renames to `<name>`
  on success. On cancel or failure the partial file is deleted.
- Progress is throttled to about 10 updates per second. Cancel is done by returning
  non-zero from the libmtp progress callback.

### Upload (Mac → phone)
- Accepts file URLs dropped into the content area or chosen via the Upload button.
- Folders are recreated recursively on the device.
- Before uploading: free-space check against the target storage; name-conflict
  check against the cached + refreshed listing (MTP allows duplicate names).
- Conflict dialog: **Replace** (delete existing object, then upload), **Keep Both**
  (append " 2", " 3", …), **Skip**; "Apply to all" checkbox. Default action
  configurable in Settings.

### Other operations
- Delete: confirmation required ("This can't be undone"). Folders are deleted recursively.
- Rename: inline edit in the file view.
- New folder: creates "untitled folder" (localized), immediately in rename mode.

### Quick Look
- Space downloads the file into a temp cache (`~/Library/Caches/<bundle id>/preview`),
  then opens `QLPreviewPanel`. Shows progress for large files. The cache is cleared on quit.

## 5. User interface

- **Window:** `NavigationSplitView`. System glass sidebar/toolbar on macOS 26+.
- **Sidebar:** "Devices" section. Each phone with its storages beneath
  (Internal, SD card) and a thin capacity bar; eject button per device.
- **Toolbar:** back/forward; current-folder title with path pop-up menu;
  icon/list view toggle; New Folder; Upload; search field (filters the current folder);
  Transfers button (progress ring → popover with active/finished jobs, cancel,
  Show in Finder).
- **Content:** icon grid (with thumbnails) and sortable list (Name, Size,
  Date Modified, Kind). Implemented with AppKit views (`NSCollectionView` /
  `NSTableView`) wrapped for SwiftUI, if the drag-out spike (§9) shows SwiftUI
  can't support file promises, multi-select and inline rename reliably.
- **Empty and error states** (`ContentUnavailableView`):
  - No device: connect → unlock → choose "File transfer" in the USB notification
    (with illustration).
  - Locked / charge-only: "Unlock your phone and choose File transfer". Retries
    automatically.
  - Claimed by Image Capture / `ptpcamerad`: banner explaining the cause, with
    a "Release" button that terminates the claiming process and retries.
- **Keyboard:** ⌘↑ parent folder, ↩ rename, ⌘⌫ delete, Space Quick Look,
  ⇧⌘N new folder, ⌘R refresh, ⌘1/⌘2 icon/list view. All actions also in
  context menus and the menu bar.
- **Settings:** default download folder, default conflict action (Ask / Replace
  / Keep Both / Skip), show hidden files.
- **Localization:** String Catalog with English and Russian, including plural
  rules (1 файл / 2 файла / 5 файлов). Sizes and dates via system formatters.
- **Accessibility:** VoiceOver labels on all controls and file items.

## 6. Error handling

- **Unplug / lock mid-transfer:** job → Failed with Retry. Local `.partial`
  removed. For uploads, attempt to delete the incomplete object on the device
  if it's still reachable.
- **Helper crash:** DeviceStore detects XPC interruption, relaunches helper,
  re-enumerates. Running jobs → "Interrupted — Retry"; queued jobs resume.
- **Helper hang (watchdog):** list-folder requests time out after 15 s; transfers
  time out after 30 s with no progress. On timeout, the helper is terminated and
  relaunched (this also interrupts other devices' transfers, a known
  consequence of the single-helper design).
- **Free space:** checked before upload; insufficient space is reported before
  any bytes are sent.
- **User-facing messages:** every `MTPError` maps to a localized message plus a
  suggested fix where possible. Raw libmtp codes appear only in diagnostics.
- **Diagnostics:** `os.Logger` across app and helper. Help → Copy Diagnostics
  copies recent logs, macOS version, device model and Android version to the
  clipboard.

## 7. Testing

- **Unit tests** (MTPKit + app logic) against `FakeDevice`, which simulates:
  disconnect after N bytes, hangs, full storage, duplicate names, slow responses.
  Covers TransferQueue, conflict resolution, listing cache, helper-restart
  recovery, watchdog, partial-file cleanup.
- **UI:** SwiftUI previews backed by `FakeDevice`; XCUITest smoke flows (browse,
  upload, download, rename, delete) with the helper replaced by a fake service
  via a launch argument.
- **Real-device checklist** (`docs/testing/device-checklist.md`), run manually
  before each release: Pixel, Samsung, Xiaomi; file > 4 GB; unplug
  mid-transfer; locked phone; Image Capture open; two phones at once.
- **CI (GitHub Actions):** build + unit tests on every PR. Tagged releases:
  build, sign, notarize, create DMG, update the Sparkle appcast. Requires the
  maintainer's Developer ID certificate as repository secrets.

## 8. Repository layout

```
Tether/
  Tether.xcodeproj
  Tether/              # app target (SwiftUI + AppKit bridges)
  MTPHelper/           # XPC service target
  Packages/MTPKit/     # shared types, protocols, FakeDevice
  Vendor/              # build script for libusb + libmtp universal dylibs
  TetherTests/  TetherUITests/
  docs/superpowers/specs/  docs/testing/
  .github/workflows/
```

## 9. Risks & early spikes

1. **Drag-out via file promises from SwiftUI**: confirms whether the
   content views must be AppKit-backed. Done first in the plan.
2. **libmtp universal build + embedding in an XPC service** with correct
   `@rpath` and code signing / notarization.
3. **Image Capture (`ptpcamerad`) claiming the device**: verify detection and
   the release flow on macOS 15 and 26/27.
