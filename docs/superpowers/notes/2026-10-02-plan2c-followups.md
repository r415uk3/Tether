# Plan 2c follow-ups

Branch `feat/reliability` (231a9e3..f058833). Items deferred during per-task and whole-branch review. Start Plan 2d with "Do first".

## Do first
- **Verify Release on a real phone.** Check that ptpcamerad (launchd on-demand) doesn't relaunch and re-grab the phone within the 500 ms window. Check that a release usually ends in success, not "still held", while the helper's 3 s retry timer is running.
- **Fix actor-isolation warnings.** They are at `FileGridView.swift:97-98` and `FileTableView.swift:120-121`: nonisolated calls to `QuickLookController.shared.attach/detach`. They predate 2c, but `detach` now reaches `PreviewCache.cancelAll()`, which mutates @Observable state.
- **Startup spinner can hang.** If the helper never answers `devices()` at launch, ContentView spins forever (`hasLoaded`). XPC `send` has no timeout. Also set `hasLoaded = true` in `DeviceStore.apply(_:)`, or add a timeout.

## Reliability
- A concurrent rescan during Release can report a false "still held". It clears on the next `.devicesChanged`.
- Release has no timeout if the helper hangs without crashing; the button stays disabled until the helper is interrupted.
- PID reuse between listing and `kill`. The window is tiny and the process is re-checked before `kill`.
- Any running ptpcamerad means an open failure is shown as "claimed". This is a heuristic: another app such as OpenMTP or adb holding the interface is mislabelled.
- Preview downloads have no watchdog of their own. A hung helper leaves "Preparing preview… NN%" up until something invalidates it.
- `isDeviceBusy` goes false slightly early after `PreviewCache.cancelAll()`.
- `.underlying` errors with varying messages would defeat the "log Open failed only on change" dedupe.

## UX
- With two phones, the detail pane shows the first ready phone. A claimed second phone can be released only from the sidebar.
- Preview progress is global across windows and per file with multi-select (no "2 of 5").
- Swapping the Quick Look controller while the panel is open (list/grid switch, rename) cancels the download.
- Retry is hidden for downloads that failed with `.phoneReconnected`, even though a download retry could work. Plan-mandated.
- Repeated Copy Diagnostics clicks queue alerts. App and helper logs aren't merged by time.
- The fake device has `osVersion: nil`, so smoke runs show "Android ?".

## Code / tests
- ThumbnailStore: the 90% eviction target is untested. There is no re-store test. Prune tie order is unstable. Prune goes by mtime (LRW, not LRU). Prune may delete a concurrent `.atomic` temp file.
- `DiagnosticLog` is `@unchecked Sendable` with NSLock; `Mutex` is available on macOS 15. A Logger is built per record.
- `Race` in AppModel duplicates `OnceContinuation`. The losing task isn't cancelled.
- Untested: the listing-failure log line, the XPC failure path for `.releaseDevice`, AppModel-level preview progress → `noteDeviceActivity`.
- The preview progress test relies on a ~200 ms window (`eventually` 3 s).
- `QuickLookController` pending fields stay set if `QLPreviewPanel.shared()` returns nil (unreachable).

## Plan 2d scope (unchanged)
String Catalog en+ru (all new 2c strings are `String(localized:)` / `LocalizedStringKey`), VoiceOver, XCUITest, Liquid Glass.
