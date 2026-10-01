# Plan 1 follow-ups (carry into Plans 2–3)

Collected from the Plan 1 review loop on 2026-10-01. The final whole-branch review triaged these as Plan 2/3 work or acceptable as-is; nothing here blocks Plan 1.

## Must land in Plan 2
- Table selection is index-based: keep selection by objectID across resort/reload and clear it on folder change — **before or with the Delete (⌘⌫) UI**, or Delete could remove the wrong files.
- Stable device identity: DeviceID is bus-devnum, so retrying after an unplug/replug always fails .deviceDisconnected. Add the serial (spec §3) and key on it.
- Real-phone check: a very large folder (e.g. DCIM with ~10k photos) may exceed the 15 s listing timeout and restart the helper repeatedly. If so, switch listing to an inactivity watchdog.

## Deferred review findings (verbatim from the ledger)
- Task 1: minor (deferred): lipo output libmtp.9.dylib is unsigned; relies on Xcode embed codeSign:true (prototype confirmed this works) — revisit in Plan 3 signing.
- Task 2: minor (deferred): MTPHelper/Info.plist hardcodes CFBundleShortVersionString 1.0 / CFBundleVersion 1 instead of $(MARKETING_VERSION)/$(CURRENT_PROJECT_VERSION) — fix in Plan 3 (versioning/Sparkle).
- Task 2: minor (deferred): TetherCoreTests/ScaffoldTests asserts nothing — plan-mandated placeholder, deleted in Task 11.
- Task 3: minor (deferred): MTPError.unexpectedResponse message not String(localized:) — handle with Plan 2 String Catalog.
- Task 3: minor (deferred): MTPError.from doesn't map CancellationError → .cancelled.
- Task 3: minor (deferred): no test for withTimeout mapping onTimeout-induced operation error to .timeout; storageFull text unchecked.
- Task 3: minor (deferred): commit trailers name the implementing model (e.g. Sonnet) rather than Opus 5.5 — acceptable/accurate.
- Task 4: minor (deferred): disconnectAfter overshoots by < chunkSize and is a no-op if n >= total; upload force-unwrap at end; Data(contentsOf:) after insert leaves orphan on missing source; partial entry size stays 0; folder download writes empty file; stray releaseHang pre-releases.
- Task 5: minor (deferred): DeviceWorker never deallocs unless shutdown() called (LocalMTPService must shut down on every removal/restart path — it does per plan); failed-by-shutdown job body may still be running on device; perform ignores task cancellation; strict priority can starve background; shutdown test doesn't assert device open while job blocked; sleep-based ordering tests.
- Task 6: minor (deferred): .partial suffix can exceed 255-byte names; folder walk has no cycle/depth guard and isn't cancellable; no initial progress callback for folders; stale .partial from crash forces "name 2".
- Task 7: minor (deferred): nil fileSize → 0; scan errors not normalized via MTPError.from; no progress callback for empty/zero-byte trees; no test for non-cancel device failure mid-upload or cleanup on unreachable device; `keeping` set redundant post conflict check.
- Task 7: minor (deferred): a top-level upload source that is itself a symlink is followed (scan root not checked).
- Task 8: minor (deferred): devices() during an in-flight first scan returns partial list (corrected by later devicesChanged event); cancellation registry stale entries (TransferQueue uses fresh attempt IDs per retry, so harmless); cancelled queued job waits until dequeued; no final progress for zero-byte transfers; provider.open blocks a pool thread and opens are serial; close() on actor.
- Task 8: minor (deferred): device replugged during an in-flight open stays hidden until the next rescan (opening marker kept when generation bumps); real-provider double-open during restart recovery to verify in T13 on hardware.
- Task 9: minor (deferred): endpoint event-handler registration races first call on relaunch; restart could SIGKILL a reused pid after helper crash (verify proc_pidpath); ObjectIdentifier reuse in invalidation handler (use weak ===); no deinit invalidate; rename/delete don't check .ok; caller cancellation doesn't stop wait; no test for event delivery after reconnect.
- Task 10: minor (deferred, TRIAGE AT FINAL): any LIBMTP_Detect_Raw_Devices error returns [] → rescan treats all phones unplugged and aborts running transfers; should only clear on NO_DEVICE_ATTACHED.
- Task 10: minor (deferred, TRIAGE AT FINAL): LIBMTP_Get_Storage may return 1 on success-with-IDs-only; guard should be < 0.
- Task 10: minor (deferred): every storages() error mapped to .deviceLocked; root listing parent_id 0 not normalized to rootID; error stack not cleared before each op; IOServiceAddMatchingNotification result ignored; all open failures → claimedByOtherProcess (Plan 2); thread-confinement doc comment inaccurate.
- Task 11: minor (deferred): loadStorages swallows errors (no retry); CancellationError shown as listing error; createFolder doesn't refresh on failure; delete partial failure not itemized.
- Task 11: minor (deferred): DeviceStore.generations never pruned; timed-out/removed test timing-weak.
- Task 12: minor (deferred): restart is global so a stall on one phone interrupts others (single-helper design, spec §6 acknowledges); cancel of a hung running job reports serviceInterrupted after watchdog; checkForStalls resets lastActivity to injected now; onJobFinished fires on all terminal states; per-event Task hops may reorder devicesChanged; test gaps (parallel devices, late cancel of old attempt, completion-once after retry, .interrupted reload, watchdog loop).
- Task 12: minor (deferred, TRIAGE AT FINAL): a restart() whose rescan hangs on a wedged provider.open leaves isRestarting true → whole queue silently frozen.
- Task 12: minor (deferred): keep-alive (0,0) events bypass the 10 Hz throttle (one per listed folder).
- Task 12: minor (deferred): any device op arriving while a later rescan is still opening that device throws .deviceDisconnected; an explicit rescan skipping an opening device emits devicesChanged without it (UI flicker).
- Task 13: minor (deferred, TRIAGE AT FINAL): old path briefly applied to newly selected storage (junk list call + title flash) — move path @State into BrowserView.
- Task 13: minor (deferred, TRIAGE AT FINAL): NSTableView selection/scroll index-based, stale across folder changes/resorts → wrong files in multi-drag.
- Task 13: minor (deferred): written file can differ from promised URL on name collision; error/progress overlays block drops; Transfers button hidden with no storage selected; .modified sort no tie-break; no keyboard open; NSOpenPanel not a sheet; start() reruns on window reopen.
