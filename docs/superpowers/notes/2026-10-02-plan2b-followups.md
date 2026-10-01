# Plan 2b follow-ups (carry into Plan 2c)

Collected from the Plan 2b review loop on 2026-10-02. Nothing here blocks Plan 2b.

## Do first in Plan 2c
- Test hygiene: the AppModel preview-busy test uses the real `~/Library/Caches/dev.tether.Tether/preview` and clears it. Inject a temp directory (`AppModel(service:previewDirectory:)`) and wait with `eventually { isDownloading }` instead of a 100 ms sleep.
- Bound the thumbnail caches: `ThumbnailStore` keeps raw Data for every thumbnail seen (~200 MB after scrolling a 10k-photo DCIM). Add an NSCache/LRU plus disk eviction.
- Cancel superseded/closed Quick Look downloads (`PreviewCache.cancel(entry:)`); today they keep the phone busy until they finish.
- Treat only `LIBMTP_Get_Storage < 0` as a failed connection probe (1 means partial success) in `objectInfo` and `thumbnail`.
- Quick Look progress for large files (spec §4).
- Still open from Plan 2a: very large folders vs the 15 s listing timeout (real-phone check).

## Deferred review findings (verbatim from the ledger)
- Task 1: minor (deferred): libmtp object cache freshness (device opened Uncached, so likely fresh) — confirm on hardware.
- Task 1: minor (deferred): disconnect detection couples to lastError's code -1 fallback; probe rebuilds libmtp storage list (harmless).
- Task 2: minor (deferred): watchdog restart now looks like a reconnect (path reset, uploads stale) — document in 2c; retry of .phoneReconnected upload dead-ends (message says retry) — wording in 2c; no FolderRef/DeviceInfo Codable round-trip test with session.
- Task 2: minor (deferred): title / Back enabled read path for one frame after reconnect (cosmetic).
- Task 3: minor (deferred): memory/missing/disk caches unbounded (add NSCache/LRU + disk eviction in 2c or later).
- Task 3: minor (deferred): retryAfter never pruned (tiny).
- Task 4: minor (deferred): dismissing Quick Look doesn't cancel a large preview download (could cancel when last waiter leaves — 2c); preview downloads invisible to TransferQueue.isDeviceBusy; sync removeItem/createDirectory on main actor.
- Task 4: minor (deferred): cancel issued in unstructured Task could be lost if clear() precedes job registration (narrow).
- Task 5: minor (deferred): grid first responder on appear; view mode global across windows; duplicated folders-first sort (move to TetherCore); selected label styling.
- Task 5: minor (deferred): shared viewMode AppStorage across windows can clear isEditingName while another window's rename sheet is open; ⌘1/⌘2 disabled with no browser focused.
- Task 6: minor (deferred): endPreviewPanelControl leaves stale urls/empty panel when focus moves; plain Space always consumed (Finder-like); superseded preview downloads keep running (PreviewCache.cancel(entry:) later); ⌘Y menu may be disabled while panel is key (verify manually).
- Task 6: minor (deferred): Space-cancel doesn't stop the MTP transfer; visible panel keeps an old-folder file after invalidate; currentPreviewItemIndex not reset on reload; nonisolated(unsafe) vs Unchecked convention.
- Task 6: minor (deferred): view switch (⌘1/⌘2) with a pending selection-follow download drops it (self-heals); detach clears dataSource/delegate even if a new controller attached first; no reconnect to the new view after switch until next show().
- Ruling: residual "new AppModel test uses the real ~/Library/Caches/.../preview dir and clear()s it" — parked, surfaced to user; fix = AppModel(previewDirectory:) injection + temp dir, eventually{isDownloading} instead of sleep — cost if wrong: running the test suite empties the local Tether preview cache (cache only, no user files).
- Ruling: residual "Get_Storage returning 1 (partial success) treated as failure in objectInfo/thumbnail probes" — parked to 2c (use < 0) — cost if wrong: on a device that returns 1, missing objects report disconnected.
