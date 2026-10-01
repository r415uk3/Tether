# Plan 2a follow-ups (carry into Plan 2b)

Collected from the Plan 2a review loop on 2026-10-02. Nothing here blocks Plan 2a.

## Do first in Plan 2b
- Replace the pre-download *parent-folder listing* (stale-handle check in `Transfers.download`) with a single-object check via `LIBMTP_Get_Filemetadata` (GetObjectInfo). Today a drag of N files from a huge folder costs N full listings and can approach the 30 s stall watchdog.
- Re-target the download fault-injection tests: the verify listing now consumes FakeDevice's first injected fault, so mid-transfer `.partial` cleanup is no longer exercised.
- Detect reconnects with a per-connection generation in `DeviceInfo` (a detach+attach inside one device-list update, or a retry racing that update, is currently missed for uploads).
- Still open from Plan 1: very large folders vs the 15 s listing timeout (needs a real-phone check).

## Deferred review findings (verbatim from the ledger)
- Task 1: minor (deferred): worker(_:) still accepts raw transport keys; collision check ignores unavailable IDs; fallback-ID device not promoted back; no tests for restart/stale-open under remapped key; placeholder serials (e.g. 0123456789ABCDEF) could alias different phones → consider manufacturer+model+serial in ID (TRIAGE AT FINAL).
- Task 2: minor (deferred): cleanup failure leaves temp item unnamed in error; storageFull on Replace needs full new size (message could explain); clash detection exact-match vs case-insensitive Android storage (TRIAGE AT FINAL); Replace may swap file↔folder.
- Task 3: minor (deferred): XPC test covers only .keepBoth; mixed-version app/helper would fail to decode upload (ship together).
- Task 4: minor (deferred, TRIAGE AT FINAL): clash/rename comparisons are case-sensitive but Android shared storage is usually case-insensitive ("A.TXT" vs "a.txt" planned as no-clash → device error; rename to "B.txt" beside "b.txt" reported valid) — same root as Task 2 minor.
- Task 4: minor (deferred): missing tests (NUL name, skip+in-drop duplicate, remaining after applyToAll); make ask closure explicitly @MainActor; NFC/NFD equivalence.
- Task 5: minor (deferred): field shows old name until rename round-trips; invalid name exits edit mode; label-style field may not scroll / lacks focus ring (manual check); right-click empty space doesn't clear selection; keyboard context menu; Modified sort tie-break; close window mid-edit; "Delete 0 items?" flash; Return = Replace default in conflict alert; drops before listing loads skip conflict checks (TRIAGE AT FINAL).
- Task 5: minor (deferred): renameContext siblings snapshot not live; requested rename dropped silently if makeFirstResponder fails.
- Task 6: minor (deferred, TRIAGE AT FINAL): ⌘↑/⌘↓ stay enabled while editing a name → navigating mid-rename silently discards typed text (data-safe); gate goUp/open on !editing.
- Ruling: residual "every download lists its whole parent folder first (N listings for N items; can approach 30 s stall watchdog on huge folders)" — parked as load-bearing follow-up, surfaced to user; fix = single-object check via LIBMTP_Get_Filemetadata (GetObjectInfo) — cost if wrong: slow multi-file drags from very large folders until fixed.
- Ruling: residual "verify consumes FakeDevice's first injected fault, so mid-transfer cleanup tests no longer exercise .partial removal" — parked, fix with the single-object check (tests re-targeted) — cost if wrong: a regression in partial cleanup could go unnoticed.
- Ruling: residual "reconnect missed when one device-list update covers detach+attach (ready→ready), and retry racing the device-list update" — parked to Plan 2b (per-connection generation in DeviceInfo); downloads already protected by verify — cost if wrong: rare stale-handle upload on a fast replug.
- Ruling: residual "possible false -6 invalidation after helper restart if the relaunched helper briefly reports .unavailable" — parked, fails safe with a clear message; confirm on hardware — cost if wrong: uploads queued during a helper restart must be re-dropped.
