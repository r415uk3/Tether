# Plan 3 follow-ups

Branch `feat/distribution` (73ef43e..802b63f). These items were deferred during the per-task and whole-branch reviews. Task 5 (go public, release 1.0.0) runs after this branch merges. Its steps are in the plan.

## Before or during Task 5
- In Step 2, after the history rewrite, delete or force-update every old remote tag and branch, not just `main`. Any ref left pointing at an old commit still carries the email. In the zero-hit check, prefer `grep -cF`.
- Commit SHAs from before the rewrite stay reachable through merged PR pages (`refs/pull/*`). Only GitHub Support can purge them.
- `release.yml` has never run. The first tag is its first real test, and the plan's fix-forward procedure applies.
- The `macos-26` runner label and the Xcode version it selects are unverified until the first CI run on the PR.

## UI tests on the maintainer's Mac
- With the Kazakh/Cyrillic keyboard layout active, the typing tests fail, because `typeText`/`typeKey` follow the layout. Switch to an ABC/US layout before running the UI tests. Follow-up: add a check in `setUp` that fails fast with a clear message when the layout isn't ABC/US.
- The UI tests inherit the real `dev.tether.Tether` defaults, including the persisted split-view frames. A collapsed sidebar hides `app.outlines["sidebar"]`. Follow-up: launch with a reset, for example by passing that split-view defaults key as a launch argument.

## Signing
- Both `MTPHelper.entitlements` and `Tether.entitlements` carry `com.apple.security.cs.disable-library-validation`, because ad-hoc signatures have no Team ID. Remove both when a Developer ID exists, enable the commented notarization hook in `release.yml`, and drop `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` only if notarization needs it.
- Users must use **Open Anyway** in Privacy & Security on first launch. A Developer ID would remove that step.

## Code and CI
- There is a leftover doc comment at `Tether/UpdaterCommands.swift:28`.
- `release.yml` calls `git ls-remote --exit-code origin gh-pages` without `--heads`, so a tag named `gh-pages` would also match.
- actionlint reports SC2010 on the `ls | grep` used to pick Xcode in both workflows. The warning is cosmetic.
- The cache key ignores the Xcode/SDK version. `xcodegen` is not pinned. CI builds twice, because of the string-sync step.
- An appcast feed minified onto one line would insert new items after the existing ones. Only `appcast.sh` writes the feed.
- If the push to `gh-pages` fails after the Release is created, the Release exists with no appcast entry. Recover with the procedure in RELEASING.md.
- Several small items: duplicate PNG blobs in the icon set, `Helvetica-Light` in `Credits.rtf`, a manual edit to `credits.txt` when library versions change, `stat -f` (macOS-only), and the `file | grep` SIGPIPE edge case in the universal-binary check.
