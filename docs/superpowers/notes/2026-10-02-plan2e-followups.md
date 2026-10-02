# Plan 2e follow-ups

Branch `feat/navigation` (2452551..ac3fc89). Items deferred during the per-task and whole-branch reviews. With Plan 2e, every spec §5 item is implemented. The next plan is Plan 3, distribution.

## Verify by hand
- With a real phone, press Eject during a large download. The job should end "Cancelled", with no file left in Downloads and no partial `.partial` file.
- After Eject, unplug the phone and plug it back in. It should reappear.
- With a text field focused, check what ⌘E does. In the search field it is disabled, so the system's "Use Selection for Find" applies. Also check it in the rename field.
- Russian: check that «Поиск в этой папке», «Извлечь», «Вперёд» and «Тип» fit in the toolbar, the menus and the column header.

## Behaviour
- A helper restart (watchdog or crash) forgets ejections. An ejected phone that is still plugged in reappears afterwards. To fix, have `AppModel` remember ejected IDs and re-send them after `.interrupted`.
- Eject aborts at the next progress callback. A libmtp call that blocks before its first callback, or the rename and delete steps of a Replace swap, still completes after Eject.
- Ejecting a phone while its own preview downloads can briefly show "device disconnected" (only `.cancelled` is suppressed).
- If the cancelled preview was the newest job, ejecting phone A clears the preview progress subtitle even though phone B's preview is still downloading.
- History is per storage, because `ContentView` gives `BrowserView` an `.id(selection)`. Finder keeps a single history across locations. The spec only asks for Back/Forward.
- Folders renamed or deleted after you visit them keep their old names in history and the path menu. Back then shows the folder error state.
- Quick Look isn't invalidated when a search hides the item it is previewing.
- Uploads and drops made while a search is active don't appear until the search is cleared (by design).

## Code / tests
- `LibMTPProvider.attachedDevices()` (USB I/O via `LIBMTP_Detect_Raw_Devices`) and the stale-handle `close()` still run on the `LocalMTPService` actor. They only block that one actor, not the thread pool. Moving them off the actor adds scan reentrancy (an older detect result landing after a newer one) and needs its own design.
- There is no eject→cancel upload test. Upload shares the download's stop path.
- There is no test for the `onChange(session)` history reset wiring or the path menu, and no UI test for the eject confirmation dialog.
- `FileKindTests` only asserts that "Document" is non-empty, because system strings vary by OS.
- `TetherUITests.swift:13–31` has main-actor warnings in setUp and tearDown. They predate Plan 2e, and the app build itself is warning-free.
- The "%lld transfers will stop." Russian `many` form could read «будет остановлено» (style).
- The `NavigationHistory` `ControlGroup` has no group-level accessibility label.
