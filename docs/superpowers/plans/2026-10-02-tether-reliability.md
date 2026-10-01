# Tether Reliability & States (Plan 2c) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tether behaves well when things go wrong:
- Image Capture holding the phone becomes a one-click **Release**.
- Every "nothing to show" moment gets a clear, specific screen.
- Help → **Copy Diagnostics** produces a report ready to paste into a bug.
- The Plan 2b leftovers are closed: test hygiene, bounded caches, cancellable and visible Quick Look downloads.

**Architecture:**
- **MTPKit** gains:
  - a libproc-based `ImageCaptureAgent` (find and terminate `ptpcamerad`)
  - `DeviceProvider.releaseClaims()`
  - `MTPService.releaseDevice(_:)` and `MTPService.diagnostics()`, plus their XPC messages
  - an in-process `DiagnosticLog` ring buffer (mirrored to `os.Logger`)
  - `DeviceInfo.osVersion`
- **TetherCore** gains:
  - storage-load error tracking in `DeviceStore`
  - `TransferQueue.Job.canRetry`
  - a pure `DiagnosticsReport` builder
  - preview download progress and cancellation in `PreviewCache`
  - an LRU memory cap and disk pruning in `ThumbnailStore`
- **The app** gains a `NoPhoneView`, device-specific empty states, Release buttons and a Help menu command.

**Tech Stack:** Swift 6 language mode, SwiftUI, AppKit (`NSPasteboard`), libproc (`proc_listallpids`, `proc_name`), `os.Logger`, libmtp (`LIBMTP_Get_Deviceversion`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-01-tether-design.md` (§5 empty/error states and the Image Capture banner, §6 diagnostics)
**Follow-ups addressed:** `docs/superpowers/notes/2026-10-02-plan2b-followups.md` ("Do first in Plan 2c")

**Plan series:**
- **2c (this plan):** reliability and states.
- **2d:**
  - English and Russian String Catalog
  - VoiceOver labels
  - XCUITest smoke flows
  - Liquid Glass polish
- **3:** distribution.

**Branching:** `feat/reliability` from `main`, with a single PR into `main`.

## Global Constraints

- **Platform and language:** minimum macOS 15.0, Swift 6 language mode with strict concurrency, and no `@preconcurrency` imports. Use `Unchecked<T>` for AppKit/XPC values that cross isolation.
- **Localization:** user-facing strings use `String(localized:)` or `LocalizedStringKey`.
- **Image Capture (spec §5):** when the phone is claimed by Image Capture (`ptpcamerad`), the sidebar and the detail view show why, with a **Release** button. Release terminates the claiming process and retries. Tether never terminates a process the user didn't ask it to.
- **Diagnostics (spec §6):** Help → Copy Diagnostics copies:
  - recent app and helper log lines
  - the macOS version and the app version
  - each phone's manufacturer, model, Android version and state

  Logs and the report never contain file names, folder names or device serial numbers. Log object IDs, sizes and error codes instead.
- **Empty states (spec §5):**
  - **No phone:** the steps "connect → unlock → choose File transfer", with an illustration of the USB notification.
  - **Locked or charge-only:** "Unlock your phone and choose File transfer". Retries happen automatically.
- **Caches:**
  - Thumbnails: memory holds at most `ThumbnailStore.defaultMemoryLimit` (1500) items, and the disk cache is pruned to at most 256 MB, oldest first.
  - Quick Look: preview downloads are cancelled when the preview is closed, superseded or invalidated.
- **Tests:** tests never write to or clear the real `~/Library/Caches/dev.tether.Tether` directories. Use injected temp directories.
- **Project file:** the Xcode project is generated from `project.yml`. Run `xcodegen generate` after adding files under `Tether/`.

## Review Focus

1. **The phone stays claimed after Release** (`ptpcamerad` restarts and grabs it again, or the release fails). The device must stay "unavailable — claimed" with Release still offered, and must not show a spinner forever. Pinned in Task 4, `releaseThatDoesNotFreeTheDeviceKeepsItClaimed`.
2. **A phone that becomes ready but whose storage list fails to load** must show an error with Try Again, not "No Phone Connected" (the Plan 1 follow-up). Pinned in Task 6, `storageLoadFailureIsRecordedAndRetried`.
3. **Retry on an upload that can never succeed** (stale after a reconnect, or `.phoneReconnected`) must not be offered. Pinned in Task 6, `staleAndReconnectedUploadsCannotBeRetried`.
4. **Quick Look closed mid-download:** closing or superseding Quick Look during a large preview download must stop the download, so the phone isn't busy. Pinned in Task 3, `cancelAllStopsDownloadsAndFreesTheDevice`.
5. **Diagnostics with no helper or no phones:** Copy Diagnostics must still produce a report, saying the helper log is unavailable. Pinned in Task 5, `reportWithoutHelperOrDevices`.

---

## File Structure

```
Packages/MTPKit/Sources/MTPKit/
  ImageCaptureAgent.swift         # NEW: find/terminate ptpcamerad via libproc (T4)
  DiagnosticLog.swift             # NEW: ring buffer + os.Logger (T5)
  Models.swift                    # MODIFY: DeviceInfo.osVersion (T5)
  MTPDevice.swift                 # MODIFY: DeviceProvider.releaseClaims() + default (T4)
  MTPService.swift                # MODIFY: releaseDevice (T4), diagnostics (T5)
  LocalMTPService.swift           # MODIFY: release (T4), logging + osVersion + diagnostics (T5)
  FakeDeviceProvider.swift        # MODIFY: claimed slots + releaseClaims (T4)
  XPC/*.swift                     # MODIFY (T4, T5)
Packages/MTPKit/Sources/TetherCore/
  AppModel.swift                  # MODIFY: cache directories (T1), progress routing (T3), diagnostics (T5)
  ThumbnailStore.swift            # MODIFY: memory LRU + disk prune (T2)
  PreviewCache.swift              # MODIFY: progress + cancelAll (T3)
  TransferQueue.swift             # MODIFY: updateProgress returns Bool (T3), canRetry + logging (T5/T6)
  DeviceStore.swift               # MODIFY: storageErrors, release(_:) (T4/T6)
  DiagnosticsReport.swift         # NEW (T5)
MTPHelper/
  LibMTPDevice.swift              # MODIFY: probe < 0 (T1), osVersion (T5)
  LibMTPProvider.swift            # MODIFY: claim detection + releaseClaims (T4)
Tether/
  QuickLookController.swift       # MODIFY: cancel on invalidate (T3)
  BrowserView.swift               # MODIFY: preview progress subtitle (T3)
  BrowserCommands.swift           # MODIFY: Help → Copy Diagnostics (T5)
  TetherApp.swift                 # MODIFY: commands (T5)
  NoPhoneView.swift               # NEW (T6)
  DeviceStateView.swift           # NEW: detail view for unavailable / loading / failed devices (T6)
  ContentView.swift, SidebarView.swift, TransfersPopover.swift   # MODIFY (T6)
```

Run every command from the repo root, `~/Tether`.

---

### Task 1: Test hygiene and connection-probe correctness

**Files:**
- Modify: `Packages/MTPKit/Sources/TetherCore/AppModel.swift`
- Modify: `Packages/MTPKit/Tests/TetherCoreTests/AppModelTests.swift` (the preview-busy test)
- Modify: `MTPHelper/LibMTPDevice.swift`

**Interfaces:**
- Produces: `AppModel.init(service: any MTPService, thumbnailDirectory: URL? = ThumbnailStore.defaultDirectory, previewDirectory: URL = PreviewCache.defaultDirectory)`.

**Why:**
- The Plan 2b preview-busy test wrote to the real preview cache and then cleared it, and it used a 100 ms sleep.
- libmtp's `LIBMTP_Get_Storage` returns 1 for "storage IDs only" (partial success). The probes in `objectInfo` and `thumbnail`, and `storages()` itself, treated that as failure.

- [ ] **Step 1: Inject the cache directories**

In `AppModel.swift`:
1. Change the initializer signature to:

```swift
    public init(service: any MTPService,
                thumbnailDirectory: URL? = ThumbnailStore.defaultDirectory,
                previewDirectory: URL = PreviewCache.defaultDirectory) {
```

2. Build the stores with them: `thumbnails = ThumbnailStore(service: service, directory: thumbnailDirectory)` and `previews = PreviewCache(service: service, directory: previewDirectory)`.

- [ ] **Step 2: Fix the preview-busy test**

In `Packages/MTPKit/Tests/TetherCoreTests/AppModelTests.swift`, find the test that starts `model.previews.file(for:…)` and refreshes during the preview. Change it so that:
1. It creates the model with temp directories: `AppModel(service: service, thumbnailDirectory: try makeTempDirectory(), previewDirectory: try makeTempDirectory())`.
2. It replaces the fixed sleep before refreshing with `try await eventually { model.previews.isDownloading(deviceID: "p1") }`.
3. It removes the trailing `model.previews.clear()`. The temp directory makes it unnecessary.

Also grep `Packages/MTPKit/Tests` for `PreviewCache(` and `.clear()`. No test may use `PreviewCache.defaultDirectory` or `ThumbnailStore.defaultDirectory` while writing files.

- [ ] **Step 3: Run the tests**

Run: `swift test --package-path Packages/MTPKit`
Expected: all tests pass.

Run: `ls ~/Library/Caches/dev.tether.Tether/preview 2>&1`
Expected: the directory doesn't exist, or it holds nothing created by the test run.

- [ ] **Step 4: Treat only negative `Get_Storage` results as failure**

In `MTPHelper/LibMTPDevice.swift`:
1. In `storages()`, change `guard LIBMTP_Get_Storage(h, 0) == 0 else { throw lastError(h) }` to:

```swift
        // 0 = full storage info; 1 = storage IDs only (partial success); negative = failure.
        guard LIBMTP_Get_Storage(h, 0) >= 0 else { throw lastError(h) } // 0 = LIBMTP_STORAGE_SORTBY_NOTSORTED
```

2. In both connection probes (in `objectInfo` and `thumbnail`), change `if LIBMTP_Get_Storage(h, 0) != 0 {` to `if LIBMTP_Get_Storage(h, 0) < 0 {`.

- [ ] **Step 5: Build the app**

Run: `xcodegen generate && xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Debug -derivedDataPath DerivedData build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add -A Packages/MTPKit MTPHelper
git commit -m "test: isolate cache directories in tests; treat Get_Storage partial success as success"
```

---

### Task 2: Bounded thumbnail caches

**Files:**
- Modify: `Packages/MTPKit/Sources/TetherCore/ThumbnailStore.swift`
- Test: `Packages/MTPKit/Tests/TetherCoreTests/ThumbnailStoreTests.swift` (add)

**Interfaces:**
- Consumes: `ThumbnailStore` (Plan 2b): `request`, `cached`, `pendingCount`, the injectable `now`, and `FakeDevice.thumbnailCalls`.
- Produces:
  - `ThumbnailStore.init(service:directory:memoryLimit: Int = ThumbnailStore.defaultMemoryLimit, now:)`
  - `public static let defaultMemoryLimit = 1500`
  - `public static let defaultDiskLimit: UInt64 = 256 * 1024 * 1024`
  - `public nonisolated static func pruneDirectory(_ directory: URL, toAtMost maxBytes: UInt64) async`, which deletes the oldest files (by modification date) until the total is ≤ `maxBytes`
  - The store prunes its directory once, in the background, when it is created.

**Eviction rule:**
- When `memory.count` exceeds `memoryLimit`, the oldest-stored entries are evicted until the count is at 90% of the limit (FIFO by insertion).
- An evicted thumbnail is re-read from disk on its next `request`, without asking the phone.

- [ ] **Step 1: Write the failing tests**

Add inside `ThumbnailStoreTests`:

```swift
    @Test func memoryLimitEvictsOldestButDiskStillServesThem() async throws {
        let photos = (0..<3).map { device.addFile("p\($0).jpg", data: Data(count: 10)) }
        for photo in photos { device.setThumbnail(Data("t\(photo.objectID)".utf8), for: photo.objectID) }
        provider.attach(device)
        let service = LocalMTPService(provider: provider)
        _ = try await service.devices()
        let store = ThumbnailStore(service: service, directory: try makeTempDirectory(), memoryLimit: 2)
        for photo in photos {
            store.request(photo, in: folder)
            try await eventually { store.pendingCount == 0 }
        }
        #expect(store.cached(photos[0], deviceID: "p1") == nil) // evicted
        #expect(store.cached(photos[2], deviceID: "p1") != nil)
        let calls = device.thumbnailCalls
        store.request(photos[0], in: folder)
        try await eventually { store.cached(photos[0], deviceID: "p1") != nil }
        #expect(device.thumbnailCalls == calls) // came back from disk, not the phone
    }

    @Test func pruneDeletesOldestFilesUntilUnderTheLimit() async throws {
        let dir = try makeTempDirectory()
        let fm = FileManager.default
        for (i, name) in ["old", "middle", "new"].enumerated() {
            let url = dir.appendingPathComponent(name)
            try Data(count: 100).write(to: url)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(1_000 + i))],
                                 ofItemAtPath: url.path)
        }
        await ThumbnailStore.pruneDirectory(dir, toAtMost: 200)
        #expect(try fm.contentsOfDirectory(atPath: dir.path).sorted() == ["middle", "new"])
        await ThumbnailStore.pruneDirectory(dir, toAtMost: 1_000) // already under: nothing removed
        #expect(try fm.contentsOfDirectory(atPath: dir.path).count == 2)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/MTPKit --filter ThumbnailStoreTests`
Expected: compile errors: `extra argument 'memoryLimit'`, `has no member 'pruneDirectory'`.

- [ ] **Step 3: Implement the limits**

In `ThumbnailStore.swift`:

1. Add the constants and stored state:

```swift
    public static let defaultMemoryLimit = 1500
    public static let defaultDiskLimit: UInt64 = 256 * 1024 * 1024
    @ObservationIgnored private let memoryLimit: Int
    /// Insertion order of `memory`'s keys, oldest first (FIFO eviction).
    @ObservationIgnored private var memoryOrder: [ItemKey] = []
```

2. Replace the initializer:

```swift
    public init(service: any MTPService, directory: URL? = ThumbnailStore.defaultDirectory,
                memoryLimit: Int = ThumbnailStore.defaultMemoryLimit,
                now: @escaping @MainActor () -> Date = Date.init) {
        self.service = service
        self.directory = directory
        self.memoryLimit = max(1, memoryLimit)
        self.now = now
        if let directory {
            Task.detached(priority: .background) {
                await ThumbnailStore.pruneDirectory(directory, toAtMost: ThumbnailStore.defaultDiskLimit)
            }
        }
    }
```

3. Replace `store(_:for:)`:

```swift
    private func store(_ data: Data, for key: ItemKey) {
        if memory.updateValue(data, forKey: key) == nil { memoryOrder.append(key) }
        if memory.count > memoryLimit {
            let target = max(1, memoryLimit * 9 / 10)
            let excess = memory.count - target
            for old in memoryOrder.prefix(excess) { memory[old] = nil }
            memoryOrder.removeFirst(min(excess, memoryOrder.count))
        }
        version += 1
    }
```

4. Add the pruning helper:

```swift
    /// Deletes the least recently written files until the directory holds at most `maxBytes`.
    public nonisolated static func pruneDirectory(_ directory: URL, toAtMost maxBytes: UInt64) async {
        await Task.detached {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
            guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
            var files: [(url: URL, size: UInt64, date: Date)] = []
            for url in urls {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                files.append((url, UInt64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast))
            }
            var total = files.reduce(UInt64(0)) { $0 + $1.size }
            for file in files.sorted(by: { $0.date < $1.date }) where total > maxBytes {
                if (try? fm.removeItem(at: file.url)) != nil { total -= min(file.size, total) }
            }
        }.value
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/MTPKit`
Expected: all tests pass, including the 2 new ones.

- [ ] **Step 5: Commit**

```bash
git add -A Packages/MTPKit
git commit -m "feat(TetherCore): bound thumbnail memory (FIFO) and prune the disk cache"
```

---

### Task 3: Quick Look downloads: cancellation and progress

**Files:**
- Modify: `Packages/MTPKit/Sources/TetherCore/PreviewCache.swift`, `TransferQueue.swift`, `AppModel.swift`
- Modify: `Tether/QuickLookController.swift`, `Tether/BrowserView.swift`
- Test: `Packages/MTPKit/Tests/TetherCoreTests/PreviewCacheTests.swift` (add), `AppModelTests.swift` (add)

**Interfaces:**
- Consumes: `PreviewCache` (Plan 2b), `ServiceEvent.progress(jobID:done:total:)`, and `TransferQueue.updateProgress(attempt:done:total:)`.
- Produces:
  - `PreviewCache` becomes `@Observable`. It adds `public private(set) var progress: Double?`, the fraction (0–1) of the most recently started in-flight download, or nil when none is running.
  - `PreviewCache.updateProgress(jobID: UUID, done: UInt64, total: UInt64) -> Bool`, which is true if the job belongs to the cache.
  - `PreviewCache.cancelAll()`, which cancels and forgets in-flight downloads but keeps finished files.
  - `TransferQueue.updateProgress(attempt:done:total:)` now returns `Bool` (`@discardableResult`): true if the attempt belongs to a job.
  - `AppModel.handle(.progress)` routes to the transfers first, then to the previews.
  - `QuickLookController.invalidate()` calls `cancelAll()` on the cache it last used.
  - BrowserView's subtitle shows "Preparing preview… NN%" while a preview downloads.

- [ ] **Step 1: Write the failing tests**

Add inside `PreviewCacheTests`:

```swift
    @Test func cancelAllStopsDownloadsAndFreesTheDevice() async throws {
        let big = device.addFile("big.bin", data: Data(count: 200 * 1024)) // ~0.4 s with the suite's device
        let (cache, _) = try await makeCache()
        let download = Task { try await cache.file(for: big, deviceID: "p1") }
        try await eventually { cache.isDownloading(deviceID: "p1") }
        cache.cancelAll()
        #expect(!cache.isDownloading(deviceID: "p1"))
        await #expect(throws: (any Error).self) { try await download.value }
        let small = device.addFile("a.txt", data: Data("x".utf8))
        let url = try await cache.file(for: small, deviceID: "p1") // the device is free again
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func progressTracksTheRunningDownload() async throws {
        let file = device.addFile("a.bin", data: Data(count: 10))
        let (cache, _) = try await makeCache()
        #expect(cache.progress == nil)
        #expect(cache.updateProgress(jobID: UUID(), done: 1, total: 2) == false) // unknown job
        let download = Task { try await cache.file(for: file, deviceID: "p1") }
        _ = try await download.value
        #expect(cache.progress == nil) // nothing running any more
    }
```

Add inside `AppModelTests`:

```swift
    @Test func previewProgressEventsReachThePreviewCache() async throws {
        provider.attach(device)
        let file = device.addFile("big.bin", data: Data(count: 100_000))
        let model = AppModel(service: LocalMTPService(provider: provider),
                             thumbnailDirectory: try makeTempDirectory(), previewDirectory: try makeTempDirectory())
        await model.start()
        let preview = Task { try await model.previews.file(for: file, deviceID: "p1") }
        try await eventually { (model.previews.progress ?? 0) > 0 }
        _ = try await preview.value
        #expect(model.previews.progress == nil)
    }
```

(`AppModelTests`' `device` is `FakeDevice(id: "p1", chunkSize: 1024, chunkDelay: 0.002)`, so 100 kB takes about 0.2 s.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/MTPKit --filter "PreviewCacheTests|AppModelTests"`
Expected: compile errors: `has no member 'cancelAll'`, `has no member 'progress'`.

- [ ] **Step 3: `PreviewCache`: progress and `cancelAll`**

In `PreviewCache.swift`:
1. Add `import Observation`, and annotate the class with `@Observable` (keep `@MainActor`).
2. Mark the existing stored properties `@ObservationIgnored`: `service`, `directory`, `ready` and `inFlight`.
3. Add the observable state and its helpers:

```swift
    /// Fraction (0–1) of the most recently started preview download, or nil when none is running.
    public private(set) var progress: Double?
    @ObservationIgnored private var fractions: [UUID: Double] = [:]
    @ObservationIgnored private var newestJob: UUID?

    /// Routes a service progress event; returns false if the job isn't a preview download.
    @discardableResult
    public func updateProgress(jobID: UUID, done: UInt64, total: UInt64) -> Bool {
        guard fractions[jobID] != nil else { return false }
        fractions[jobID] = total == 0 ? 0 : min(1, Double(done) / Double(total))
        refreshProgress()
        return true
    }

    private func refreshProgress() {
        progress = newestJob.flatMap { fractions[$0] }
    }

    /// Cancels every preview download in flight (Quick Look closed or moved on); finished files stay cached.
    public func cancelAll() {
        let service = self.service
        for running in inFlight.values {
            let jobID = running.jobID
            Task { await service.cancel(jobID: jobID) }
        }
        inFlight.removeAll()
        fractions.removeAll()
        newestJob = nil
        refreshProgress()
    }
```

4. In `file(for:deviceID:)`, right after `inFlight[key] = InFlight(...)`, register the job:

```swift
        fractions[jobID] = 0
        newestJob = jobID
        refreshProgress()
```

5. Extend the existing `defer` so it also forgets the job:

```swift
        defer {
            if inFlight[key]?.token == token { inFlight[key] = nil } // clear() may have replaced it
            fractions[jobID] = nil
            if newestJob == jobID { newestJob = nil }
            refreshProgress()
        }
```

6. In `clear()`, replace the cancel loop and `inFlight.removeAll()` with a call to `cancelAll()`. Keep `ready.removeAll()` and the directory removal.

- [ ] **Step 4: Route progress in `AppModel` and `TransferQueue`**

In `TransferQueue.swift`, change `updateProgress(attempt:done:total:)` to `@discardableResult public func updateProgress(attempt: UUID, done: UInt64, total: UInt64) -> Bool`. Return `false` from the guard when no job matches, and `true` at the end.

In `AppModel.handle(_:)`, replace the `.progress` case:

```swift
        case .progress(let attempt, let done, let total):
            if !transfers.updateProgress(attempt: attempt, done: done, total: total) {
                previews.updateProgress(jobID: attempt, done: done, total: total)
            }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path Packages/MTPKit`
Expected: all tests pass.

- [ ] **Step 6: Cancel from Quick Look and show progress**

In `Tether/QuickLookController.swift`:
1. Add `private weak var lastCache: PreviewCache?`.
2. In `show(_:deviceID:cache:onError:)`, set `lastCache = cache` before `invalidate()`. The current order is `invalidate()` first, so put `lastCache = cache` above it.
3. In `invalidate()`, add `lastCache?.cancelAll()` after `pendingRequest = nil`.

In `Tether/BrowserView.swift`, replace the `.navigationSubtitle(...)` modifier:

```swift
            .navigationSubtitle(subtitle(for: listing))
```

Then add:

```swift
    private func subtitle(for listing: DeviceStore.Listing?) -> String {
        if let fraction = model.previews.progress {
            return String(localized: "Preparing preview… \(Int(fraction * 100))%")
        }
        return listing?.isUpdating == true ? String(localized: "Updating…") : ""
    }
```

- [ ] **Step 7: Build and launch**

Run: `xcodegen generate && xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Debug -derivedDataPath DerivedData build 2>&1 | grep -E "error:|warning: .*Tether/|BUILD"`
Expected: `** BUILD SUCCEEDED **`, with no warnings from `Tether/`.

Run: `DerivedData/Build/Products/Debug/Tether.app/Contents/MacOS/Tether -UseFakeDevices YES & PID=$!; sleep 4; kill -0 $PID && echo alive; kill $PID`
Expected: `alive`

- [ ] **Step 8: Commit**

```bash
git add -A Packages/MTPKit Tether
git commit -m "feat: cancel Quick Look downloads when the preview closes; show preview progress"
```

---

### Task 4: Release a phone held by Image Capture

**Files:**
- Create: `Packages/MTPKit/Sources/MTPKit/ImageCaptureAgent.swift`
- Modify: `Packages/MTPKit/Sources/MTPKit/MTPDevice.swift`, `MTPService.swift`, `LocalMTPService.swift`, `FakeDeviceProvider.swift`, `XPC/XPCMessages.swift`, `XPC/MTPXPCEndpoint.swift`, `XPC/XPCMTPService.swift`
- Modify: `Packages/MTPKit/Sources/TetherCore/DeviceStore.swift`
- Modify (test double): `FlakyService` in `DeviceStoreTests.swift`
- Modify: `MTPHelper/LibMTPProvider.swift`
- Test: `Packages/MTPKit/Tests/MTPKitTests/ReleaseTests.swift` (new), `XPCTests.swift` (add), `DeviceStoreTests.swift` (add)

**Interfaces:**
- Produces:
  - `public enum ImageCaptureAgent`:
    - `static let processNames: [String] = ["ptpcamerad"]`
    - `static func runningProcessIDs() -> [pid_t]`, via `proc_listallpids` and `proc_name`
    - `@discardableResult static func terminate() -> Bool`, which sends SIGTERM to each running agent and returns true if at least one was signalled
  - `DeviceProvider.releaseClaims() -> Bool`, with a protocol extension default that returns `false`
  - `MTPService.releaseDevice(_ deviceID: DeviceID) async throws`, implemented by `LocalMTPService` as:
    1. Ask the provider to release claims; if nothing was released, throw `.claimedByOtherProcess`.
    2. Wait 0.5 s for the agent to let go.
    3. Rescan.
    4. Throw `.claimedByOtherProcess` if the device is still claimed afterwards.
  - XPC: `XPCRequest.releaseDevice(deviceID:)` → `.ok`
  - `DeviceStore.release(_ id: DeviceID) async -> MTPError?`, which returns nil on success, otherwise the error
  - `FakeDeviceProvider.attachClaimed(_ device: FakeDevice, as key: DeviceID? = nil, releasable: Bool = true)` and `releaseClaimsCalls: Int`
- `LibMTPProvider.open` changes: when `LIBMTP_Open_Raw_Device_Uncached` fails, it throws `.claimedByOtherProcess` only if `ImageCaptureAgent.runningProcessIDs()` is non-empty. Otherwise it throws `.underlying(code: -7, message: String(localized: "Tether couldn’t connect to the phone. Unplug it, plug it back in, and choose “File transfer”."))`.

- [ ] **Step 1: Write the failing tests**

`Packages/MTPKit/Tests/MTPKitTests/ReleaseTests.swift`:

```swift
import Foundation
import Testing
@testable import MTPKit

@Suite struct ReleaseTests {
    let provider = FakeDeviceProvider()

    @Test func releaseFreesAClaimedDevice() async throws {
        provider.attachClaimed(FakeDevice(id: "serial-A"), as: "14-4")
        let service = LocalMTPService(provider: provider)
        #expect(try await service.devices().first?.state == .unavailable(.claimedByOtherProcess))
        try await service.releaseDevice("14-4")
        #expect(provider.releaseClaimsCalls == 1)
        let devices = try await service.devices()
        #expect(devices.map(\.id) == ["serial-A"])
        #expect(devices.first?.state == .ready)
    }

    @Test func releaseThatDoesNotFreeTheDeviceKeepsItClaimed() async throws {
        provider.attachClaimed(FakeDevice(id: "serial-A"), as: "14-4", releasable: false)
        let service = LocalMTPService(provider: provider)
        _ = try await service.devices()
        await #expect(throws: MTPError.claimedByOtherProcess) { try await service.releaseDevice("14-4") }
        #expect(try await service.devices().first?.state == .unavailable(.claimedByOtherProcess))
    }

    @Test func nothingToReleaseIsReported() async throws {
        provider.attachUnavailable(AttachedDevice(id: "14-9", manufacturer: "S", model: "S25"), error: .deviceLocked)
        let service = LocalMTPService(provider: provider) // FakeDeviceProvider releases nothing here
        _ = try await service.devices()
        await #expect(throws: MTPError.claimedByOtherProcess) { try await service.releaseDevice("14-9") }
    }

    @Test func agentLookupDoesNotCrashAndFindsNoFakeProcess() {
        // Real libproc call; on a test machine ptpcamerad may or may not run, but a bogus name never matches.
        _ = ImageCaptureAgent.runningProcessIDs()
        #expect(ImageCaptureAgent.processIDs(named: "tether-no-such-process-\(UUID().uuidString.prefix(6))").isEmpty)
    }
}
```

Add inside `XPCTests`:

```swift
    @Test func releaseCrossesXPC() async throws {
        provider.attachClaimed(FakeDevice(id: "serial-B"), as: "14-5")
        let (client, host) = makeClient()
        _ = try await client.devices()
        try await client.releaseDevice("14-5")
        #expect(try await client.devices().contains { $0.id == "serial-B" && $0.state == .ready })
        withExtendedLifetime(host) {}
    }
```

Add inside `DeviceStoreTests`:

```swift
    @Test func releaseReportsFailure() async throws {
        provider.attachUnavailable(AttachedDevice(id: "14-9", manufacturer: "S", model: "S25"), error: .claimedByOtherProcess)
        let (store, _) = makeStore()
        await store.reloadDevices()
        #expect(await store.release("14-9") == .claimedByOtherProcess)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/MTPKit --filter "ReleaseTests|XPCTests|DeviceStoreTests"`
Expected: compile errors: `has no member 'attachClaimed'`, `cannot find 'ImageCaptureAgent'`.

- [ ] **Step 3: `ImageCaptureAgent.swift`**

```swift
import Darwin
import Foundation

/// The macOS agents that grab PTP/MTP phones for Image Capture and Photos.
public enum ImageCaptureAgent {
    public static let processNames: [String] = ["ptpcamerad"]

    public static func runningProcessIDs() -> [pid_t] {
        processNames.flatMap { processIDs(named: $0) }
    }

    /// PIDs of this user's processes with exactly this name (libproc).
    public static func processIDs(named name: String) -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).filter { pid in
            guard pid > 0 else { return false }
            var buffer = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self) == name
        }
    }

    /// Asks every running agent to quit (SIGTERM). Returns true if at least one was signalled.
    @discardableResult
    public static func terminate() -> Bool {
        var signalled = false
        for pid in runningProcessIDs() where kill(pid, SIGTERM) == 0 { signalled = true }
        return signalled
    }
}
```

- [ ] **Step 4: Provider and service API**

`MTPDevice.swift`:
- Add to `protocol DeviceProvider`:

```swift
    /// Frees phones held by other apps (Image Capture). Returns true if anything was released.
    func releaseClaims() -> Bool
```

- Add after the protocol:

```swift
public extension DeviceProvider {
    func releaseClaims() -> Bool { false }
}
```

`FakeDeviceProvider.swift`:
1. Add a slot case `case claimed(FakeDevice, releasable: Bool)`. Its `attached(as:)` uses the device's manufacturer and model, like `.device`. In `open`, it fails with `.claimedByOtherProcess`.
2. Add the state and API:

```swift
    private var releases = 0

    /// Attaches a device that another app holds until `releaseClaims()` (if `releasable`).
    public func attachClaimed(_ device: FakeDevice, as key: DeviceID? = nil, releasable: Bool = true) {
        lock.withLock { slots[key ?? device.info.id] = .claimed(device, releasable: releasable) }
    }

    public var releaseClaimsCalls: Int { lock.withLock { releases } }

    public func releaseClaims() -> Bool {
        lock.withLock {
            releases += 1
            var released = false
            for (key, slot) in slots {
                if case .claimed(let device, true) = slot {
                    slots[key] = .device(device)
                    released = true
                }
            }
            // A non-releasable claim still "signals" the agent but the phone stays held.
            return released || slots.values.contains { if case .claimed = $0 { true } else { false } }
        }
    }
```

`MTPService.swift`: add the requirement:

```swift
    /// Frees a phone held by Image Capture and reconnects. Throws `.claimedByOtherProcess` if it stays held.
    func releaseDevice(_ deviceID: DeviceID) async throws
```

`LocalMTPService.swift`:

```swift
    public func releaseDevice(_ deviceID: DeviceID) async throws {
        await ensureScanned()
        let provider = self.provider
        let released = await Task.detached { provider.releaseClaims() }.value
        guard released else { throw MTPError.claimedByOtherProcess }
        try? await Task.sleep(for: .milliseconds(500)) // give the agent a moment to let go of the interface
        await rescan()
        let key = key(for: deviceID)
        if case .unavailable(.claimedByOtherProcess)? = infos[key]?.state { throw MTPError.claimedByOtherProcess }
    }
```

The released device reopens under its own identity, so `deviceID` may be the transport key it had while claimed. `key(for:)` falls back to the raw key, which still names the slot.

XPC:
- `XPCMessages.swift`: add `case releaseDevice(deviceID: DeviceID)`.
- `MTPXPCEndpoint.swift`: add `case .releaseDevice(let id): try await service.releaseDevice(id); return .ok`.
- `XPCMTPService.swift`: add `public func releaseDevice(_ deviceID: DeviceID) async throws { _ = try await send(.releaseDevice(deviceID: deviceID)) }`.

`FlakyService` in `DeviceStoreTests.swift`: forward `releaseDevice` to `base`.

`DeviceStore.swift`:

```swift
    /// Asks the service to free a phone held by Image Capture; returns the error if it stays held.
    public func release(_ id: DeviceID) async -> MTPError? {
        do {
            try await service.releaseDevice(id)
            return nil
        } catch {
            return MTPError.from(error)
        }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path Packages/MTPKit`
Expected: all tests pass, including 4 `ReleaseTests`, `releaseCrossesXPC` and `releaseReportsFailure`.

- [ ] **Step 6: The helper's provider**

In `MTPHelper/LibMTPProvider.swift`:
1. Replace the open-failure branch:

```swift
        guard let handle = LIBMTP_Open_Raw_Device_Uncached(&r) else {
            if !ImageCaptureAgent.runningProcessIDs().isEmpty { throw MTPError.claimedByOtherProcess }
            throw MTPError.underlying(code: -7, message: String(
                localized: "Tether couldn’t connect to the phone. Unplug it, plug it back in, and choose “File transfer”."))
        }
```

2. Add:

```swift
    func releaseClaims() -> Bool {
        ImageCaptureAgent.terminate()
    }
```

- [ ] **Step 7: Build the app**

Run: `xcodegen generate && xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Debug -derivedDataPath DerivedData build 2>&1 | grep -E "error:|BUILD"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
git add -A Packages/MTPKit MTPHelper
git commit -m "feat: detect and release phones held by Image Capture (ptpcamerad)"
```

---

### Task 5: Diagnostics: log, Android version, report, Help menu

**Files:**
- Create: `Packages/MTPKit/Sources/MTPKit/DiagnosticLog.swift`, `Packages/MTPKit/Sources/TetherCore/DiagnosticsReport.swift`
- Modify: `Packages/MTPKit/Sources/MTPKit/Models.swift`, `MTPService.swift`, `LocalMTPService.swift`, `XPC/*.swift`
- Modify: `Packages/MTPKit/Sources/TetherCore/AppModel.swift`, `TransferQueue.swift`, `DeviceStore.swift`
- Modify (test double): `FlakyService`
- Modify: `MTPHelper/LibMTPDevice.swift`
- Modify: `Tether/BrowserCommands.swift`, `Tether/TetherApp.swift`
- Test: `Packages/MTPKit/Tests/MTPKitTests/DiagnosticLogTests.swift` (new), `Packages/MTPKit/Tests/TetherCoreTests/DiagnosticsReportTests.swift` (new)

**Interfaces:**
- Produces:
  - `public final class DiagnosticLog: Sendable`, with:
    - `static let shared`
    - `init(capacity: Int = 500)`
    - `func record(_ message: String, category: String = "general")`, which appends `"<ISO8601 time> [category] message"` and mirrors the line to `os.Logger(subsystem: "dev.tether.Tether", category:)`
    - `func snapshot() -> [String]`, oldest first and at most `capacity` lines
  - `DeviceInfo.osVersion: String?` (init parameter `osVersion: String? = nil`)
  - `MTPService.diagnostics() async throws -> [String]`: the service process's log lines (the helper's when over XPC)
  - XPC: `XPCRequest.diagnostics` → `XPCResponse.lines([String])`
  - `public enum DiagnosticsReport { static func make(appVersion: String, macOSVersion: String, devices: [DeviceInfo], appLog: [String], helperLog: [String]?) -> String }`
  - `AppModel.diagnosticsReport(appVersion: String) async -> String`
  - Help menu → **Copy Diagnostics**, which copies the report to the clipboard and confirms with an alert

**Privacy rule (Global Constraints):** log messages and the report contain no file or folder names and no device IDs or serials. The report lists devices by manufacturer, model, Android version and state only.

**What gets logged** (keep messages short; each one is a single `record` call):
- **`LocalMTPService.performScan`:**
  - a device opened: `"Opened <manufacturer> <model> (Android <osVersion or ?>)"`, category `device`
  - an open failed: `"Open failed for <model>: <error.localizedDescription>"`
  - a device was removed: `"Device removed"`
- **`LocalMTPService.restart`:** `"Service restarted"`.
- **`TransferQueue.finish`, when a job fails:** `"Transfer failed (<kind: download|upload>, <size> bytes): <error.localizedDescription>"`, category `transfer`.
- **`DeviceStore.refresh`, when it fails:** `"Listing failed: <error.localizedDescription>"`, category `browse`.

- [ ] **Step 1: Write the failing tests**

`Packages/MTPKit/Tests/MTPKitTests/DiagnosticLogTests.swift`:

```swift
import Foundation
import Testing
@testable import MTPKit

@Suite struct DiagnosticLogTests {
    @Test func keepsTheNewestLinesUpToCapacity() {
        let log = DiagnosticLog(capacity: 3)
        for i in 1...5 { log.record("event \(i)", category: "test") }
        let lines = log.snapshot()
        #expect(lines.count == 3)
        #expect(lines.map { $0.hasSuffix("[test] event 3") || $0.hasSuffix("[test] event 4") || $0.hasSuffix("[test] event 5") } == [true, true, true])
        #expect(lines.first!.hasSuffix("event 3"))
        #expect(lines.last!.hasSuffix("event 5"))
    }

    @Test func serviceLogsOpenFailuresAndReturnsTheLog() async throws {
        let provider = FakeDeviceProvider()
        provider.attachUnavailable(AttachedDevice(id: "k", manufacturer: "Samsung", model: "S25"), error: .deviceLocked)
        let service = LocalMTPService(provider: provider)
        _ = try await service.devices()
        let lines = try await service.diagnostics()
        #expect(lines.contains { $0.contains("Open failed for S25") })
    }

    @Test func deviceInfoCarriesOSVersion() throws {
        let info = DeviceInfo(id: "x", manufacturer: "Google", model: "Pixel 9", state: .ready, osVersion: "15")
        let decoded = try JSONDecoder().decode(DeviceInfo.self, from: JSONEncoder().encode(info))
        #expect(decoded.osVersion == "15")
    }
}
```

`Packages/MTPKit/Tests/TetherCoreTests/DiagnosticsReportTests.swift`:

```swift
import Foundation
import Testing
import MTPKit
@testable import TetherCore

@Suite struct DiagnosticsReportTests {
    @Test func reportListsVersionsDevicesAndLogs() {
        let devices = [
            DeviceInfo(id: "serial-SECRET", manufacturer: "Google", model: "Pixel 9", state: .ready, osVersion: "15"),
            DeviceInfo(id: "14-9", manufacturer: "Samsung", model: "Galaxy S25", state: .unavailable(.deviceLocked)),
        ]
        let report = DiagnosticsReport.make(appVersion: "0.2.0 (7)", macOSVersion: "27.0", devices: devices,
                                            appLog: ["a1"], helperLog: ["h1", "h2"])
        #expect(report.contains("Tether 0.2.0 (7)"))
        #expect(report.contains("macOS 27.0"))
        #expect(report.contains("Google Pixel 9 — Android 15 — ready"))
        #expect(report.contains("Samsung Galaxy S25 — Android ? — unavailable:"))
        #expect(report.contains("a1"))
        #expect(report.contains("h2"))
        #expect(!report.contains("SECRET")) // no serials
    }

    @Test func reportWithoutHelperOrDevices() {
        let report = DiagnosticsReport.make(appVersion: "1", macOSVersion: "15.0", devices: [], appLog: [], helperLog: nil)
        #expect(report.contains("No phones connected"))
        #expect(report.contains("Helper log unavailable"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/MTPKit --filter "DiagnosticLogTests|DiagnosticsReportTests"`
Expected: compile errors: `cannot find 'DiagnosticLog'`, `extra argument 'osVersion'`.

- [ ] **Step 3: `DiagnosticLog.swift`**

```swift
import Foundation
import os

/// A small in-memory log for Help → Copy Diagnostics, mirrored to the unified log.
/// Never record file names, folder names or device serials here.
public final class DiagnosticLog: @unchecked Sendable {
    public static let shared = DiagnosticLog()

    private let capacity: Int
    private let lock = NSLock()
    private var lines: [String] = []

    public init(capacity: Int = 500) {
        self.capacity = max(1, capacity)
    }

    public func record(_ message: String, category: String = "general") {
        let line = "\(Date().formatted(.iso8601)) [\(category)] \(message)"
        Logger(subsystem: "dev.tether.Tether", category: category).log("\(message, privacy: .public)")
        lock.withLock {
            lines.append(line)
            if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        }
    }

    public func snapshot() -> [String] {
        lock.withLock { lines }
    }
}
```

- [ ] **Step 4: Android version, service log, XPC**

1. `Models.swift`: add `public var osVersion: String?` to `DeviceInfo`. Add the init parameter `osVersion: String? = nil` after `session`, and assign it.
2. `LocalMTPService.swift`:
   - In the `.success` branch, pass `osVersion: opened.info.osVersion` when building the public `DeviceInfo`. Record `"Opened \(opened.info.manufacturer) \(opened.info.model) (Android \(opened.info.osVersion ?? "?"))"`, category `"device"`.
   - In the `.failure` branch, after storing the unavailable info, record `"Open failed for \(device.model): \(error.localizedDescription)"`, category `"device"`.
   - In the detach loop, record `"Device removed"`, category `"device"`, for each removed key.
   - In `restart()`, record `"Service restarted"`, category `"service"`.
   - Add:

```swift
    public func diagnostics() async throws -> [String] {
        DiagnosticLog.shared.snapshot()
    }
```

3. `MTPService.swift`: add the requirement `func diagnostics() async throws -> [String]`.
4. XPC: add `case diagnostics` to `XPCRequest` and `case lines([String])` to `XPCResponse`. The endpoint handles it with `case .diagnostics: return .lines(try await service.diagnostics())`. The client:

```swift
    public func diagnostics() async throws -> [String] {
        guard case .lines(let lines) = try await send(.diagnostics) else { throw MTPError.unexpectedResponse }
        return lines
    }
```

5. `FlakyService`: forward `diagnostics()` to `base`.
6. `MTPHelper/LibMTPDevice.swift`, in `init(handle:attached:)`: read `let version = Self.take(LIBMTP_Get_Deviceversion(handle))` and pass `osVersion: version` to `DeviceInfo`. On Android, the MTP device version is the Android release, for example "15".

- [ ] **Step 5: `DiagnosticsReport.swift` and `AppModel`**

```swift
import Foundation
import MTPKit

/// Plain-text report for bug reports. Contains no file names, folder names or serials.
public enum DiagnosticsReport {
    public static func make(appVersion: String, macOSVersion: String, devices: [DeviceInfo],
                            appLog: [String], helperLog: [String]?) -> String {
        var out = ["Tether \(appVersion)", "macOS \(macOSVersion)", "", "Phones:"]
        if devices.isEmpty {
            out.append("  No phones connected")
        }
        for device in devices {
            let state: String = switch device.state {
            case .ready: "ready"
            case .unavailable(let error): "unavailable: \(error.localizedDescription)"
            }
            out.append("  \(device.manufacturer) \(device.model) — Android \(device.osVersion ?? "?") — \(state)")
        }
        out += ["", "App log:"] + (appLog.isEmpty ? ["  (empty)"] : appLog.map { "  \($0)" })
        out += ["", "Helper log:"]
        if let helperLog {
            out += helperLog.isEmpty ? ["  (empty)"] : helperLog.map { "  \($0)" }
        } else {
            out.append("  Helper log unavailable")
        }
        return out.joined(separator: "\n")
    }
}
```

In `AppModel.swift`, add:

```swift
    public func diagnosticsReport(appVersion: String) async -> String {
        let helperLog = try? await service.diagnostics()
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return DiagnosticsReport.make(
            appVersion: appVersion,
            macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            devices: devices.devices,
            appLog: DiagnosticLog.shared.snapshot(),
            helperLog: helperLog)
    }
```

(In-process tests and `-UseFakeDevices` share one `DiagnosticLog.shared`, so app and "helper" lines are the same there. That's expected.)

- [ ] **Step 6: App-side log lines**

- `TransferQueue.finish(_:_:)`: when the state is `.failed(let error)`, record:

```swift
            let kind = if case .download = job.kind { "download" } else { "upload" }
            DiagnosticLog.shared.record("Transfer failed (\(kind), \(job.total) bytes): \(error.localizedDescription)",
                                        category: "transfer")
```

- `DeviceStore.refresh`: in the `.failure(let error)` branch, record `"Listing failed: \(error.localizedDescription)"`, category `"browse"`.

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test --package-path Packages/MTPKit`
Expected: all tests pass, including 3 `DiagnosticLogTests` and 2 `DiagnosticsReportTests`.

- [ ] **Step 8: Help menu**

In `Tether/BrowserCommands.swift`, add:

```swift
struct DiagnosticsCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Copy Diagnostics") { copyDiagnostics() }
        }
    }

    private func copyDiagnostics() {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        Task { @MainActor in
            let report = await model.diagnosticsReport(appVersion: version)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
            let alert = NSAlert()
            alert.messageText = String(localized: "Diagnostics Copied")
            alert.informativeText = String(localized: "Paste them into your bug report. They don’t include file names.")
            alert.runModal()
        }
    }
}
```

In `Tether/TetherApp.swift`, change `.commands { BrowserCommands() }` to:

```swift
        .commands {
            BrowserCommands()
            DiagnosticsCommands(model: model)
        }
```

- [ ] **Step 9: Build and launch**

Run: `xcodegen generate && xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Debug -derivedDataPath DerivedData build 2>&1 | grep -E "error:|warning: .*Tether/|BUILD"`
Expected: `** BUILD SUCCEEDED **`, with no warnings from `Tether/`.

Run: `DerivedData/Build/Products/Debug/Tether.app/Contents/MacOS/Tether -UseFakeDevices YES & PID=$!; sleep 4; kill -0 $PID && echo alive; kill $PID`
Expected: `alive`

- [ ] **Step 10: Commit**

```bash
git add -A Packages/MTPKit MTPHelper Tether
git commit -m "feat: Help → Copy Diagnostics (app + helper log, versions, phones; no file names)"
```

---

### Task 6: Empty and error states, Release buttons, retry rules

**Files:**
- Modify: `Packages/MTPKit/Sources/TetherCore/DeviceStore.swift`, `TransferQueue.swift`
- Create: `Tether/NoPhoneView.swift`, `Tether/DeviceStateView.swift`
- Modify: `Tether/ContentView.swift`, `Tether/SidebarView.swift`, `Tether/TransfersPopover.swift`
- Test: `Packages/MTPKit/Tests/TetherCoreTests/DeviceStoreTests.swift` (add), `TransferQueueTests.swift` (add)

**Interfaces:**
- Consumes: `DeviceStore.release(_:)` (Task 4), `MTPError` (incl. `.claimedByOtherProcess`, `.deviceLocked`, `.phoneReconnected`), and `TransferQueue.Job.isStale` (Plan 2a).
- Produces:
  - `DeviceStore.storageErrors: [DeviceID: MTPError]` (public, read-only). `loadStorages` records a failure there and clears it on success. `apply` drops entries for devices that are no longer ready.
  - `TransferQueue.Job.canRetry: Bool`. It is false for stale uploads and for jobs that failed with `.phoneReconnected`, and true otherwise for failed or cancelled jobs.
  - `NoPhoneView`: numbered steps plus a mock of Android's "Use USB for" notification with "File transfer" chosen.
  - `DeviceStateView(device:)`, the detail view when no storage is selected. It shows one of:
    - "Reading your phone…" while storages load
    - a storage error with Try Again
    - claimed by another app, with **Release**
    - locked, with "Waiting for you to unlock…"
    - any other unavailable error
  - The sidebar shows a **Release** button on claimed devices.

**`ContentView` detail when there is no selection, in priority order:**
1. If there are no devices: `NoPhoneView`.
2. Otherwise, take the first device, preferring ready devices: `DeviceStateView(device:)`.

- [ ] **Step 1: Write the failing tests**

Add inside `DeviceStoreTests`:

```swift
    @Test func storageLoadFailureIsRecordedAndRetried() async throws {
        let (store, _) = makeStore()
        device.inject(.fail(.deviceBusy)) // consumed by the first storages() call
        await store.reloadDevices()
        try await eventually { store.storageErrors["p1"] == .deviceBusy }
        #expect(store.storages["p1"] == nil)
        await store.loadStorages("p1")
        #expect(store.storageErrors["p1"] == nil)
        #expect(store.storages["p1"]?.isEmpty == false)
    }
```

(If the first `storages()` call happens before `reloadDevices()` returns, through the `apply` → `loadStorages` task, the injected fault is consumed there. The `eventually` waits for it.)

Add inside `TransferQueueTests`:

```swift
    @Test func staleAndReconnectedUploadsCannotBeRetried() async throws {
        let (queue, _) = try await makeQueue()
        let file = try makeTempDirectory().appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: file)
        let stale = FolderRef(deviceID: "p1", storageID: 1, session: UUID()) // not the current session
        let id = queue.enqueueUpload(file, to: stale)
        try await eventually { queue.jobs.first { $0.id == id }?.state == .failed(.phoneReconnected) }
        #expect(queue.jobs.first { $0.id == id }?.canRetry == false)
        device.inject(.fail(.deviceBusy))
        let other = queue.enqueueDownload(device.addFile("b.txt", data: Data("b".utf8)), deviceID: "p1",
                                          into: try makeTempDirectory())
        try await eventually { queue.jobs.first { $0.id == other }?.state == .failed(.deviceBusy) }
        #expect(queue.jobs.first { $0.id == other }?.canRetry == true)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/MTPKit --filter "DeviceStoreTests|TransferQueueTests"`
Expected: compile errors: `has no member 'storageErrors'`, `has no member 'canRetry'`.

- [ ] **Step 3: Implement**

`DeviceStore.swift`:
1. Add `public private(set) var storageErrors: [DeviceID: MTPError] = [:]`.
2. Replace `loadStorages`:

```swift
    public func loadStorages(_ id: DeviceID) async {
        do {
            let list = try await service.storages(deviceID: id)
            guard isReady(id) else { return }
            storages[id] = list
            storageErrors[id] = nil
        } catch {
            guard isReady(id) else { return }
            storageErrors[id] = MTPError.from(error)
            DiagnosticLog.shared.record("Storage list failed: \(MTPError.from(error).localizedDescription)",
                                        category: "browse")
        }
    }
```

3. In `apply(_:)`, after filtering `storages`, add the same filter for errors: `storageErrors = storageErrors.filter { now[$0.key] != nil && !fresh.contains($0.key) }`.

`TransferQueue.swift`: add to `Job`:

```swift
        /// False when retrying can't succeed (the upload belongs to an earlier connection).
        public var canRetry: Bool {
            switch state {
            case .failed(.phoneReconnected): false
            case .failed, .cancelled: !isStale
            default: false
            }
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/MTPKit`
Expected: all tests pass.

- [ ] **Step 5: `Tether/NoPhoneView.swift`**

```swift
import SwiftUI

/// Shown when no phone is connected: what to do, with a picture of Android's USB notification.
struct NoPhoneView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "cable.connector")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Connect an Android Phone").font(.title2.bold())
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Connect the phone with a USB cable.")
                step(2, "Unlock the phone.")
                step(3, "In the USB notification, choose “File transfer”.")
            }
            USBNotificationMock()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.bold())
                .frame(width: 22, height: 22)
                .background(Circle().fill(.tint.opacity(0.2)))
            Text(text)
        }
    }
}

/// A simplified drawing of Android's "Use USB for" choice with File transfer selected.
private struct USBNotificationMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Use USB for", systemImage: "usb")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            option("File transfer", selected: true)
            option("USB tethering", selected: false)
            option("MIDI", selected: false)
            option("No data transfer", selected: false)
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Example: in the phone’s USB notification, File transfer is selected.")
    }

    private func option(_ title: LocalizedStringKey, selected: Bool) -> some View {
        HStack {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Text(title).fontWeight(selected ? .semibold : .regular)
        }
        .font(.callout)
    }
}
```

`"usb"` may not exist as an SF Symbol on macOS 15. If the build or render shows a missing symbol, use `"cable.connector.horizontal"` and list it as a deviation.

- [ ] **Step 6: `Tether/DeviceStateView.swift`**

```swift
import SwiftUI
import MTPKit
import TetherCore

/// Detail view for a phone without a browsable storage: loading, failed, held by another app, or locked.
struct DeviceStateView: View {
    @Environment(AppModel.self) private var model
    let device: DeviceInfo
    @State private var releasing = false
    @State private var releaseError: String?

    var body: some View {
        switch device.state {
        case .ready:
            if let error = model.devices.storageErrors[device.id] {
                ContentUnavailableView {
                    Label("Can’t Read \(device.displayName)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.localizedDescription)
                } actions: {
                    Button("Try Again") { Task { await model.devices.loadStorages(device.id) } }
                }
            } else {
                ProgressView("Reading your phone…")
            }
        case .unavailable(.claimedByOtherProcess):
            ContentUnavailableView {
                Label("Another App Is Using \(device.displayName)", systemImage: "lock.trianglebadge.exclamationmark")
            } description: {
                Text(releaseError ?? String(localized: "Image Capture or Photos has taken the phone. Tether can ask it to let go."))
            } actions: {
                Button(releasing ? String(localized: "Releasing…") : String(localized: "Release")) { release() }
                    .disabled(releasing)
            }
        case .unavailable(.deviceLocked):
            ContentUnavailableView {
                Label("Unlock \(device.displayName)", systemImage: "lock.iphone")
            } description: {
                Text("Unlock your phone and choose “File transfer” in the USB notification. Tether connects automatically.")
            }
        case .unavailable(let error):
            ContentUnavailableView("Can’t Connect to \(device.displayName)", systemImage: "exclamationmark.triangle",
                                   description: Text(error.localizedDescription))
        }
    }

    private func release() {
        releasing = true
        releaseError = nil
        Task {
            if let error = await model.devices.release(device.id) {
                releaseError = error == .claimedByOtherProcess
                    ? String(localized: "The phone is still held by another app. Quit Image Capture and Photos, then try again.")
                    : error.localizedDescription
            }
            releasing = false
        }
    }
}
```

`"lock.iphone"` may not exist. If the symbol is missing, fall back to `"lock"` and list it as a deviation.

- [ ] **Step 7: Wire `ContentView`, `SidebarView` and `TransfersPopover`**

`ContentView.swift`: replace the `else { ContentUnavailableView(...) }` branch of the detail with:

```swift
            } else if let device = model.devices.devices.first(where: { $0.state == .ready })
                        ?? model.devices.devices.first {
                DeviceStateView(device: device)
            } else {
                NoPhoneView()
            }
```

`SidebarView.swift`, in the `.unavailable(let error)` case, add a Release button after the caption `Text` when `error == .claimedByOtherProcess`:

```swift
                            if error == .claimedByOtherProcess {
                                Button("Release") { Task { _ = await model.devices.release(device.id) } }
                                    .controlSize(.small)
                            }
```

`TransfersPopover.swift`: in `TransferRow`, show the Retry button only when `job.canRetry`. For `.failed` and `.cancelled` jobs that can't be retried, show nothing in that slot.

- [ ] **Step 8: Build and launch**

Run: `xcodegen generate && xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Debug -derivedDataPath DerivedData build 2>&1 | grep -E "error:|warning: .*Tether/|BUILD"`
Expected: `** BUILD SUCCEEDED **`, with no warnings from `Tether/`.

Run: `DerivedData/Build/Products/Debug/Tether.app/Contents/MacOS/Tether -UseFakeDevices YES & PID=$!; sleep 4; kill -0 $PID && echo alive; kill $PID`
Expected: `alive`

- [ ] **Step 9: Commit**

```bash
git add -A Packages/MTPKit Tether
git commit -m "feat(app): no-phone guide, device state screens, Release buttons, retry only when it can work"
```

**Manual checklist** (for the human):
1. **No phones** (real mode with nothing plugged in): the numbered steps and the USB-notification drawing appear.
2. **Fake mode:** select the locked Galaxy. Its detail says "Unlock Galaxy S25…".
3. **Real phone with Image Capture open:**
   - The phone shows "Another App Is Using…" with Release.
   - Release frees it, and it becomes browsable.
   - If it stays held, the message says to quit Image Capture and Photos.
4. **Diagnostics:** Help → Copy Diagnostics, then paste into a text editor. The versions and phones are listed, and no file names appear.
5. **Quick Look:** preview a large video, then close it. The "Preparing preview…" subtitle disappears and browsing stays responsive.
6. **Stale uploads:** after a replug, a stale failed upload shows no Retry button.

---

## Spec coverage (Plan 2c)

| Spec / follow-up | Task |
|---|---|
| Follow-up: test cache hygiene; `Get_Storage` partial success | 1 |
| Follow-up: bound thumbnail caches | 2 |
| Follow-up: cancel Quick Look downloads; §4 Quick Look progress | 3 |
| §5: Image Capture banner + Release | 4, 6 |
| §6: Help → Copy Diagnostics (logs, macOS version, device model, Android version) | 5 |
| §5: empty states (no phone with illustration, locked, claimed); Plan 1 follow-up "storage load failure shows No Phone" | 6 |
| Plan 2b follow-up: no dead-end Retry for reconnected uploads | 6 |
| §5: String Catalog en+ru, VoiceOver; §7 UI tests; Liquid Glass polish | Plan 2d |
