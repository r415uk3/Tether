# Tether Plan 3: Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Tether 1.0.0 as a free, public, MIT-licensed download. That means:
- an ad-hoc signed universal DMG on GitHub Releases
- Sparkle auto-updates fed from GitHub Pages
- CI that builds and tests every PR and publishes releases from `v*` tags
- the licence, acknowledgements, README and app icon a public release needs

**Architecture:**
- `scripts/build-release.sh` builds the Release app, ad-hoc signs it inside-out, verifies it, and packages a DMG. The same script runs on a developer Mac and in CI.
- Sparkle 2 (SPM) provides updates. The appcast lives on the `gh-pages` branch, and each DMG is signed with an EdDSA key whose private half exists only as a GitHub secret.
- Two GitHub Actions workflows:
  - `ci.yml` runs on PRs and on pushes to main.
  - `release.yml` runs on `v*` tags.
- A final controller-run step does the work that only the maintainer can authorise:
  1. Rewrite git history to the noreply email.
  2. Make the repo public.
  3. Enable Pages.
  4. Add the secret.
  5. Tag `v1.0.0`.

**Tech Stack:** Swift 6, SwiftUI/AppKit, XcodeGen, Sparkle 2 (SPM), `codesign`, `hdiutil`, GitHub Actions (macOS runners), `gh`, `git filter-repo`.

**Spec:** `docs/superpowers/specs/2026-10-01-tether-design.md`:
- §2: "App license: MIT. libmtp/libusb (LGPL-2.1) are dynamically linked and bundled, with their license texts and source links included in the app's About/Acknowledgements". Also: "Swift deps: Sparkle (SPM)".
- §7: "CI (GitHub Actions): build + unit tests on every PR. Tagged releases: build, sign, notarize, create DMG, update the Sparkle appcast."

**Maintainer decisions (2026-10-02):**
- There is no Apple Developer Program membership, so the app ships **unsigned (ad-hoc)** with no notarization. This deviates from spec §7 "sign, notarize". The release workflow keeps a clearly marked, disabled hook for Developer ID signing and notarization.
- The repo becomes **public**. Releases go on GitHub Releases, and the appcast goes on GitHub Pages (`https://r415uk3.github.io/Tether/appcast.xml`).
- The first version is **1.0.0**.
- Rewrite history author emails from `<redacted>` to `119946977+r415uk3@users.noreply.github.com` before going public. The local repo config already uses the noreply identity.
- Use a generated placeholder app icon.

## Global Constraints

- Minimum macOS 15.0. The binary is universal: arm64 and x86_64.
- Bundle ID `dev.tether.Tether`. The helper is `dev.tether.Tether.MTPHelper`.
- Swift 6 strict concurrency. The app build has no warnings.
- English and Russian UI. Every new user-facing string goes into the catalogs with Russian, and `scripts/sync-strings.sh` must leave no diff. Sparkle ships its own Russian UI.
- Diagnostics and logs never contain file names, folder names or device serials.
- Tether never terminates a process the user didn't ask it to.
- Tests never touch the real `~/Library/Caches/dev.tether.Tether`.
- **No secrets in the repo.** The Sparkle private key lives only in the maintainer's keychain and in the `SPARKLE_ED_PRIVATE_KEY` GitHub secret. The public key goes in `project.yml`.
- **No outward action without the maintainer's explicit go-ahead.** Pushing tags, changing repo visibility, force-pushing and creating releases are all controller-run steps in Task 5, never subagent steps.
- Commits use the noreply identity (local git config), with this trailer:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01RYh1t7CSXabioJFAfcnW24
  ```

## Review Focus

1. **The unsigned app on a clean Mac.** After the user clears quarantine as the README says, the ad-hoc signed app must launch, and its XPC helper must load the bundled libmtp/libusb under hardened runtime and library validation. A "different Team IDs" load failure breaks the whole app. Pinned in Task 2: `build-release.sh --smoke` launches the packaged app in real mode, then asserts that the `MTPHelper` process is running and that no new crash report exists.
2. **Universal slices everywhere.** The app, helper, both dylibs and Sparkle.framework must each contain arm64 and x86_64. Pinned in Task 2: `build-release.sh` runs `lipo -archs` over every Mach-O in the bundle and fails on a missing slice.
3. **Sparkle version ordering.** `CFBundleVersion` must increase on every release, or Sparkle never offers the update. `sparkle:version` in the appcast must equal the bundle's `CFBundleVersion`, and the tag must match `CFBundleShortVersionString`. Pinned in Task 4: `scripts/appcast.sh` asserts all three and fails otherwise.
4. **Appcast integrity.** Each item needs:
   - an EdDSA signature over the exact DMG bytes uploaded
   - the correct `length`
   - `sparkle:minimumSystemVersion` 15.0
   - an enclosure URL pointing at the GitHub Release asset

   Pinned in Task 4: `scripts/appcast.sh` writes these fields, and `xmllint --noout` validates the result. Task 3's local update test runs an end-to-end update from 1.0.0 to 1.0.1 against a locally served appcast.
5. **LGPL compliance.** The licence texts and source links for libmtp/libusb must ship inside the app and in the DMG. Pinned in Task 1, which adds `Credits.rtf`, and Task 2, where `build-release.sh` asserts the bundle contains `Credits.rtf` with "GNU Lesser General Public License" and the DMG contains `Acknowledgements.rtf`.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `LICENSE` | MIT licence text | 1 |
| `Tether/Resources/Credits.rtf` | About-panel acknowledgements: LGPL notices, source links, Sparkle MIT | 1, 3 |
| `Tether/Assets.xcassets/AppIcon.appiconset/*` | App icon, all sizes | 1 |
| `scripts/make-icon.swift` | Renders the placeholder icon PNGs | 1 |
| `README.md` | Public README: features, install (unsigned), build, privacy, licence | 1 |
| `project.yml` | Version settings, Release config, Sparkle package, Info.plist keys, Credits resource | 1–3 |
| `scripts/build-release.sh` | Release build, ad-hoc sign, verify (slices, credits, signature), DMG, `--smoke` | 2 |
| `Tether/TetherApp.swift`, `Tether/UpdaterCommands.swift`, `Tether/SettingsView.swift` | Sparkle updater, "Check for Updates…", auto-check toggle | 3 |
| `scripts/appcast.sh` | Builds or updates `appcast.xml` from a DMG + EdDSA signature | 4 |
| `.github/workflows/ci.yml`, `.github/workflows/release.yml` | CI and release automation | 4 |
| `docs/RELEASING.md` | How to cut a release, keys and secrets | 4 |

---

### Task 1: Licence, acknowledgements, README, app icon

**Files:**
- Create: `LICENSE`, `Tether/Resources/Credits.rtf`, `scripts/make-icon.swift`, `Tether/Assets.xcassets/Contents.json`, `Tether/Assets.xcassets/AppIcon.appiconset/Contents.json` + PNGs
- Modify: `README.md`, `project.yml`

**Interfaces:**
- Produces: `Credits.rtf` in the app bundle's `Contents/Resources`. The standard About panel shows it automatically. Task 3 appends Sparkle to it, and Task 2 checks it is present.

- [ ] **Step 1: LICENSE**

Create `LICENSE` with the standard MIT text: `Copyright (c) 2026 r415uk3 and Tether contributors`.

- [ ] **Step 2: Credits.rtf**

Create `Tether/Resources/Credits.rtf`. It must be valid RTF; check with `textutil -info`. Content, in English (the About panel isn't localized per language here):

```
Tether is free software under the MIT License. Source: https://github.com/r415uk3/Tether

Tether bundles and dynamically links these libraries:

libmtp 1.1.23 — GNU Lesser General Public License v2.1
Source: https://github.com/libmtp/libmtp/releases/tag/v1.1.23

libusb 1.0.30 — GNU Lesser General Public License v2.1
Source: https://github.com/libusb/libusb/releases/tag/v1.0.30

You may replace these libraries with modified versions: they live in
Tether.app/Contents/XPCServices/MTPHelper.xpc/Contents/Frameworks. The exact build script is
Vendor/build-libs.sh in Tether's repository.

[full text of the GNU LGPL v2.1]
```

Build it from a small plain-text or Markdown source with `textutil -convert rtf`. Keep the generator command in a comment in `scripts/make-icon.swift`'s sibling, or document it in `docs/RELEASING.md` in Task 4. For the full LGPL v2.1 text, use the `COPYING` file from the libmtp tarball in `Vendor/.cache` (run `Vendor/build-libs.sh` first if the cache is empty). Copy it in; don't retype it.

In `project.yml`, make sure the file is bundled as a resource. `sources: [Tether]` picks up `Tether/Resources/Credits.rtf`. Confirm after the build that `Tether.app/Contents/Resources/Credits.rtf` exists.

- [ ] **Step 3: Icon generator and asset catalog**

`scripts/make-icon.swift` is a standalone script run with `swift scripts/make-icon.swift <outdir>`. It uses AppKit/CoreGraphics to draw a 1024×1024 macOS-style icon:
- a rounded rectangle with the macOS squircle-ish corner radius, about 22.4% of the size, on a transparent canvas with a 100 px inset;
- a vertical gradient from `#3D7BFD` to `#1E4FD8`;
- a white SF Symbol, `smartphone` or `iphone.gen3` if `smartphone` is unavailable, with `cable.connector` beneath it, or a single `arrow.left.arrow.right` badge;
- a soft shadow.

Render the symbols with `NSImage(systemSymbolName:accessibilityDescription:)` and `NSImage.SymbolConfiguration(pointSize:weight:)`, tinted white.

Write PNGs for every macOS AppIcon slot: 16, 32, 64, 128, 256, 512 and 1024 px. That covers the 16/32/128/256/512 points at @1x and @2x. Also write `Contents.json`, listing each image with `"idiom":"mac"`, its `size` and its `scale`.

Run it into `Tether/Assets.xcassets/AppIcon.appiconset`, and create `Tether/Assets.xcassets/Contents.json` (`{"info":{"author":"xcode","version":1}}`).

In `project.yml`, under `targets.Tether.settings.base`, set `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`.

Commit the generated PNGs so the build doesn't need the script.

- [ ] **Step 4: README**

Rewrite `README.md` for the public. Sections:
- **What it is**, including a screenshot placeholder line.
- **Features:** browse, copy both ways (including files over 4 GB), Quick Look and thumbnails, rename/delete/new folder, Eject, Back/Forward, search, English and Russian, VoiceOver.
- **Install:**
  1. Download the DMG from Releases and drag Tether to Applications.
  2. Because Tether isn't notarized (it's a free project without an Apple Developer ID), macOS blocks the first launch. Open Tether once, then go to **System Settings → Privacy & Security** and click **Open Anyway** next to the Tether message, then confirm.
  3. Alternative for advanced users: `xattr -dr com.apple.quarantine /Applications/Tether.app`.
- **First connection:** unlock the phone and choose "File transfer" in the USB notification. If Image Capture or Photos grabs the phone, use **Release**.
- **Updates:** built in; checks GitHub for new versions. Settings → "Check for updates automatically".
- **Privacy:** no analytics or telemetry. The only network requests are update checks to `r415uk3.github.io` and downloads from `github.com`. Diagnostics stay local until you copy them.
- **Build from source:** keep the current section, plus `scripts/build-release.sh`.
- **Licence:** MIT, plus the LGPL note and a pointer to the About window and `Vendor/build-libs.sh`.

- [ ] **Step 5: Verify and commit**

Run:
```
xcodegen generate && xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Debug -derivedDataPath DerivedData build 2>&1 | grep -E "warning:|error:|BUILD"
```
Expected: `** BUILD SUCCEEDED **` with no Swift warnings.

Run:
```
ls DerivedData/Build/Products/Debug/Tether.app/Contents/Resources/ | grep -E "Credits.rtf|AppIcon"
```
Expected: `Credits.rtf` and `AppIcon.icns`, or an `Assets.car` containing it.

Launch with fake devices and a temp `-CacheDirectory`. Open Tether ▸ About Tether and take a screenshot. The about panel should show the icon and the credits. Quit the app.

```bash
git add LICENSE README.md project.yml Tether/Resources Tether/Assets.xcassets scripts/make-icon.swift
git commit -m "chore: MIT licence, LGPL acknowledgements, public README, app icon"
```

---

### Task 2: Versioning and the release build script

**Files:**
- Create: `scripts/build-release.sh`
- Modify: `project.yml` (versions and Release settings)

**Interfaces:**
- Produces:

```
scripts/build-release.sh [--version X.Y.Z] [--build N] [--smoke] [--out DIR]
```

It outputs `DIR/Tether-X.Y.Z.dmg` (default `DIR` = `dist/`) and `DIR/Tether.app`.

- Defaults:
  - `--version`: `MARKETING_VERSION` from `project.yml`
  - `--build`: `git rev-list --count HEAD`

Task 4 calls it from CI with explicit values.

- [ ] **Step 1: Version settings**

In `project.yml`, `settings.base`, set `MARKETING_VERSION: "1.0.0"` and keep `CURRENT_PROJECT_VERSION`. Both are overridden on the xcodebuild command line by the script.

Release config:
- `ONLY_ACTIVE_ARCH: NO` and `ARCHS: "arm64 x86_64"`, so the build is universal.
- `CODE_SIGN_IDENTITY: "-"`, plus `CODE_SIGN_STYLE: Manual`, which already exists.

Hardened runtime and ad-hoc library validation: the helper loads ad-hoc signed dylibs. Under hardened runtime, library validation rejects them when Team IDs differ, which is the "different Team IDs" failure seen with the UI-test bundle in Plan 2d. Decide by testing in Step 4:
- **(a)** The default (Xcode signs everything with "-") works when launched from the DMG copy. Keep it.
- **(b)** Otherwise, add an entitlements file for MTPHelper with `com.apple.security.cs.disable-library-validation = true`, and reference it with `CODE_SIGN_ENTITLEMENTS` in the MTPHelper target.

Record which one in the commit message and in `docs/RELEASING.md` (Task 4).

- [ ] **Step 2: Write `scripts/build-release.sh`**

```bash
#!/bin/bash
# Builds a universal, ad-hoc signed Release Tether.app and packages Tether-<version>.dmg.
# Usage: scripts/build-release.sh [--version X.Y.Z] [--build N] [--smoke] [--out DIR]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="" BUILD="" SMOKE=0 OUT="dist"
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --build) BUILD="$2"; shift 2 ;;
    --smoke) SMOKE=1; shift ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
[ -n "$VERSION" ] || VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([0-9.]*\)"\{0,1\}/\1/p' project.yml | head -1)
[ -n "$BUILD" ] || BUILD=$(git rev-list --count HEAD)
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad version '$VERSION'" >&2; exit 2; }
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "bad build '$BUILD'" >&2; exit 2; }

[ -f Vendor/build/lib/libmtp.9.dylib ] || Vendor/build-libs.sh
DD="$PWD/DerivedData/release"
LOG="$DD/build.log"; mkdir -p "$DD" "$OUT"
xcodegen generate >/dev/null
if ! xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Release -derivedDataPath "$DD" \
      MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" ONLY_ACTIVE_ARCH=NO \
      clean build >"$LOG" 2>&1; then
  tail -40 "$LOG" >&2; echo "release build failed (log: $LOG)" >&2; exit 1
fi
grep -E "warning: .*\.swift" "$LOG" && { echo "Swift warnings in Release build" >&2; exit 1; }

APP="$OUT/Tether.app"
rm -rf "$APP" && ditto "$DD/Build/Products/Release/Tether.app" "$APP"

# Verify: every Mach-O is universal.
fail=0
while IFS= read -r f; do
  if file "$f" | grep -q "Mach-O"; then
    archs=$(lipo -archs "$f" 2>/dev/null || true)
    [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || { echo "missing slice in $f: $archs" >&2; fail=1; }
  fi
done < <(find "$APP" -type f \( -perm -u+x -o -name "*.dylib" \))
[ $fail -eq 0 ] || exit 1

# Verify: versions, credits, signature.
plist="$APP/Contents/Info.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")" = "$VERSION" ] || { echo "version mismatch" >&2; exit 1; }
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$plist")" = "$BUILD" ] || { echo "build mismatch" >&2; exit 1; }
grep -q "GNU Lesser General Public License" "$APP/Contents/Resources/Credits.rtf" || { echo "Credits.rtf missing LGPL text" >&2; exit 1; }
codesign --verify --deep --strict "$APP" || { echo "codesign verify failed" >&2; exit 1; }

# DMG: app + Applications link + acknowledgements.
STAGE="$DD/dmg"; rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Tether.app"
ln -s /Applications "$STAGE/Applications"
cp "$APP/Contents/Resources/Credits.rtf" "$STAGE/Acknowledgements.rtf"
DMG="$OUT/Tether-$VERSION.dmg"; rm -f "$DMG"
hdiutil create -volname "Tether $VERSION" -srcfolder "$STAGE" -format UDZO -fs HFS+ "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
echo "built $DMG ($(stat -f %z "$DMG") bytes), version $VERSION ($BUILD)"

if [ $SMOKE -eq 1 ]; then
  # Mount, copy out like a user would, launch in real mode, confirm the helper loads libmtp.
  MNT=$(mktemp -d); hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null
  TRY=$(mktemp -d); ditto "$MNT/Tether.app" "$TRY/Tether.app"; hdiutil detach "$MNT" >/dev/null
  before=$(ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -c -E "^(Tether|MTPHelper)" || true)
  CACHE=$(mktemp -d)
  "$TRY/Tether.app/Contents/MacOS/Tether" -CacheDirectory "$CACHE" >/dev/null 2>&1 & pid=$!
  ok=0; for _ in $(seq 1 20); do sleep 0.5; pgrep -f "Tether.app/Contents/XPCServices/MTPHelper.xpc" >/dev/null && { ok=1; break; }; done
  sleep 2
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  after=$(ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -c -E "^(Tether|MTPHelper)" || true)
  [ $ok -eq 1 ] || { echo "smoke: MTPHelper never started" >&2; exit 1; }
  [ "$after" -le "$before" ] || { echo "smoke: new crash report in ~/Library/Logs/DiagnosticReports" >&2; exit 1; }
  echo "smoke: app launched, MTPHelper running, no crash reports"
fi
```

The helper only starts when the app connects to it. `AppModel.start()` calls `devices()` at launch, so the helper starts within about a second, and the `pgrep` loop is the check that it is running.

If the helper crashes on load (library validation), launchd keeps relaunching it, and a crash report appears. Then apply Step 1 (b).

Add `dist/` to `.gitignore`. Make the script executable.

- [ ] **Step 3: Run it**

Run: `scripts/build-release.sh --smoke`
Expected output:
- `built dist/Tether-1.0.0.dmg (… bytes), version 1.0.0 (N)`
- `smoke: app launched, MTPHelper running, no crash reports`

- [ ] **Step 4: Gatekeeper check on this Mac**

Simulate a downloaded copy:
```
xattr -w com.apple.quarantine "0081;$(printf %x $(date +%s));Safari;" dist/Tether.app
spctl -a -vv dist/Tether.app
```
Expected: `rejected`, because the app is unsigned. That is expected, and the README covers it.

Then run `xattr -dr com.apple.quarantine dist/Tether.app` and launch the app with `open dist/Tether.app --args -UseFakeDevices YES -CacheDirectory <tmp>`. It must open. Quit it.

Write the outcomes in the report. Don't change any system settings.

- [ ] **Step 5: Commit**

```bash
git add scripts/build-release.sh project.yml .gitignore MTPHelper  # MTPHelper only if an entitlements file was added
git commit -m "build: universal ad-hoc Release build and DMG packaging (scripts/build-release.sh)"
```

---

### Task 3: Sparkle auto-updates

**Files:**
- Modify: `project.yml` (package, dependency, Info.plist keys, `SPARKLE_PUBLIC_KEY`)
- Create: `Tether/UpdaterCommands.swift`
- Modify: `Tether/TetherApp.swift`, `Tether/SettingsView.swift`, `Tether/Resources/Credits.rtf` (Sparkle MIT notice), catalogs
- Test: `TetherUITests/TetherUITests.swift`

**Interfaces:**
- Produces:
  - Info.plist keys:
    - `SUFeedURL = https://r415uk3.github.io/Tether/appcast.xml`
    - `SUPublicEDKey = $(SPARKLE_PUBLIC_KEY)`
    - `SUEnableAutomaticChecks = YES`
  - The debug launch argument `-TetherFeedURL <url>` overrides the feed, for local update tests.
  - Task 4 signs releases with the private half of `SPARKLE_PUBLIC_KEY`.

- [ ] **Step 1: Generate the EdDSA key pair (controller asks the maintainer)**

This touches the maintainer's login keychain, so the implementer must **not** run it. The controller asks the maintainer to run it in Terminal after Sparkle is resolved:
```
./DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
```
It prints the public key. Use the path that exists after resolving the package, e.g. `find DerivedData -name generate_keys -path "*Sparkle*"`.

Then:
- Put the public key in `project.yml` as `SPARKLE_PUBLIC_KEY`.
- Export the private key with `generate_keys -x sparkle_private_key.txt`. The maintainer stores it as the GitHub secret `SPARKLE_ED_PRIVATE_KEY` in Task 5, then deletes the file.

**Until the key exists**, the implementer uses a throwaway key pair for local testing, generated into a temp file: `generate_keys --account tether-test` writes to the keychain, so prefer the `-x`/`-f` file-based flags if available. Never commit the throwaway key. The final public key is substituted in Task 5.

- [ ] **Step 2: Add Sparkle**

In `project.yml`:
```yaml
packages:
  MTPKit:
    path: Packages/MTPKit
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    majorVersion: 2.6.0
```
Use the latest 2.x that resolves; check with `git ls-remote --tags`.

In the Tether target's dependencies, add `- package: Sparkle` (product `Sparkle`).

In `targets.Tether.settings.base`, add these Info.plist keys:
```yaml
        INFOPLIST_KEY_SUFeedURL: https://r415uk3.github.io/Tether/appcast.xml
        INFOPLIST_KEY_SUPublicEDKey: $(SPARKLE_PUBLIC_KEY)
        INFOPLIST_KEY_SUEnableAutomaticChecks: YES
        SPARKLE_PUBLIC_KEY: "REPLACE_IN_TASK_5"
```
`GENERATE_INFOPLIST_FILE` may drop unknown `INFOPLIST_KEY_*` entries. Check the built Info.plist with `PlistBuddy`. If the keys are missing, switch the Tether target to an explicit `info:` block in XcodeGen, as MTPHelper already uses, with those properties.

Sparkle's XPC installer services aren't needed, because Tether is not sandboxed. Leave `SUEnableInstallerLauncherService` unset.

- [ ] **Step 3: Wire the updater**

`Tether/UpdaterCommands.swift`:
```swift
import SwiftUI
import Sparkle

/// Owns Sparkle's updater for the app's lifetime.
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate {
    private(set) var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    var updater: SPUUpdater { controller.updater }

    /// `-TetherFeedURL <url>` points at a test feed (local update testing only).
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "TetherFeedURL")
    }
}

struct UpdaterCommands: Commands {
    let updater: Updater
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.controller.checkForUpdates(nil) }
        }
    }
}
```

Adjust to Sparkle's actual Swift API and Swift 6 isolation. `SPUUpdaterDelegate` methods are called on the main thread. The goal is a clean build with no warnings.

`TetherApp.swift`:
- Add `private let updater = Updater()`. It is created once, at app start.
- Add `UpdaterCommands(updater: updater)` to `.commands`.
- Pass the updater into `Settings { SettingsView(updater: updater) }`.

When running with `-UseFakeDevices YES` (UI tests, demos), start the updater with `startingUpdater: false`, so tests never hit the network. Make the `Updater` initialiser take a `start: Bool`, and pass `!UserDefaults.standard.bool(forKey: "UseFakeDevices")`.

`SettingsView.swift`: add a toggle bound to `updater.updater.automaticallyChecksForUpdates`:
```swift
            Toggle("Check for updates automatically", isOn: Binding(
                get: { updater.updater.automaticallyChecksForUpdates },
                set: { updater.updater.automaticallyChecksForUpdates = $0 }))
```

- [ ] **Step 4: Strings and credits**

Run `scripts/sync-strings.sh` and add Russian:
- `Check for Updates…` → «Проверить обновления…»
- `Check for updates automatically` → «Проверять обновления автоматически»

Append to `Credits.rtf`: `Sparkle — MIT License — https://github.com/sparkle-project/Sparkle`, followed by Sparkle's licence text from the resolved package's `LICENSE`.

- [ ] **Step 5: UI test**

In `TetherUITests.swift`:
```swift
    func testCheckForUpdatesMenuExists() {
        launchToRoot()
        app.menuBars.menuBarItems["Tether"].click()
        XCTAssertTrue(app.menuItems["Check for Updates…"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }
```
Don't click the item: with `-UseFakeDevices` the updater isn't started.

- [ ] **Step 6: Local end-to-end update test (implementer)**

1. Build 1.0.0 with `scripts/build-release.sh --version 1.0.0 --build 100 --out /tmp/t-upd/old`, using the throwaway key's public half in `SPARKLE_PUBLIC_KEY` (a temporary edit, not committed).
2. Build 1.0.1 with `--build 101 --out /tmp/t-upd/new`.
3. Sign the 1.0.1 DMG with the throwaway private key using Sparkle's `sign_update`.
4. Write a one-item appcast by hand, or with Task 4's script if it already exists, pointing at `http://127.0.0.1:8765/Tether-1.0.1.dmg`.
5. Serve the directory with `python3 -m http.server 8765`.
6. Launch the old app with `-TetherFeedURL http://127.0.0.1:8765/appcast.xml -CacheDirectory <tmp>` and choose **Check for Updates…**. This needs UI. Drive it with XCUITest, or report it as a manual step for the maintainer with exact commands if automating Sparkle's window is impractical.
7. Expected: Sparkle offers 1.0.1, installs it, and relaunches it. The relaunched app's `CFBundleShortVersionString` is 1.0.1.

Restore `SPARKLE_PUBLIC_KEY` to the placeholder afterwards, and stop the server.

- [ ] **Step 7: Run everything and commit**

Run:
- `swift test --package-path Packages/MTPKit`
- the debug build: no warnings
- `scripts/build-release.sh --smoke`: Sparkle.framework is universal and signed
- the UI tests: all pass
- the sync: a second run shows no diff

```bash
git add project.yml Tether TetherUITests
git commit -m "feat: Sparkle auto-updates (Check for Updates…, automatic checks setting)"
```

---

### Task 4: CI and release workflows, appcast script, release docs

**Files:**
- Create: `.github/workflows/ci.yml`, `.github/workflows/release.yml`, `scripts/appcast.sh`, `docs/RELEASING.md`

**Interfaces:**
- Consumes:
  - `scripts/build-release.sh --version --build --out` (Task 2)
  - Sparkle's `sign_update` (Task 3)
- Produces:

```
scripts/appcast.sh <dmg> <version> <build> <download-url> <ed-signature> <appcast-in-out.xml>
```

The script prepends a new `<item>` to the appcast, creating the file if missing, then validates it.

- [ ] **Step 1: `scripts/appcast.sh`**

```bash
#!/bin/bash
# Prepends a release <item> to a Sparkle appcast and validates it.
set -euo pipefail
DMG="$1" VERSION="$2" BUILD="$3" URL="$4" SIG="$5" FEED="$6"
[ -f "$DMG" ] || { echo "no dmg $DMG" >&2; exit 2; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD" =~ ^[0-9]+$ ]] || { echo "bad version/build" >&2; exit 2; }
[ -n "$SIG" ] || { echo "empty EdDSA signature" >&2; exit 2; }
LEN=$(stat -f %z "$DMG")
DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
ITEM="    <item>
      <title>Tether $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/r415uk3/Tether/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url=\"$URL\" length=\"$LEN\" type=\"application/octet-stream\" sparkle:edSignature=\"$SIG\"/>
    </item>"
if [ ! -f "$FEED" ]; then
  cat > "$FEED" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Tether</title>
    <link>https://r415uk3.github.io/Tether/appcast.xml</link>
    <language>en</language>
  </channel>
</rss>
EOF
fi
grep -q "<sparkle:version>$BUILD</sparkle:version>" "$FEED" && { echo "build $BUILD already in feed" >&2; exit 1; }
LAST=$(sed -n 's:.*<sparkle\:version>\([0-9]*\)</sparkle\:version>.*:\1:p' "$FEED" | sort -n | tail -1)
[ -z "$LAST" ] || [ "$BUILD" -gt "$LAST" ] || { echo "build $BUILD not greater than $LAST" >&2; exit 1; }
# Insert the item right after <language>…</language>.
ITEM="$ITEM" perl -0pi -e 's#(</language>\n)#$1$ENV{ITEM}\n#' "$FEED"
xmllint --noout "$FEED"
echo "appcast: added $VERSION ($BUILD), $LEN bytes"
```

Add a small shell test, `scripts/test-appcast.sh`. It runs the script twice on a dummy DMG, building 5 and then 6, and asserts:
- two items, with the newest first;
- re-adding 6 fails;
- adding 4 fails;
- `xmllint` passes.

Run it.

- [ ] **Step 2: `ci.yml`**

```yaml
name: CI
on:
  pull_request:
  push:
    branches: [main]
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
jobs:
  build-test:
    runs-on: macos-26
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v4
      - name: Select newest Xcode
        run: |
          XC=$(ls -d /Applications/Xcode*.app | sort -V | tail -1)
          sudo xcode-select -s "$XC"
          xcodebuild -version
          xcrun --sdk macosx --show-sdk-version
      - name: Tools
        run: brew install xcodegen
      - name: Cache native libs
        uses: actions/cache@v4
        with:
          path: Vendor/build
          key: vendor-${{ runner.os }}-${{ hashFiles('Vendor/build-libs.sh') }}
      - name: Build libusb + libmtp
        run: '[ -f Vendor/build/lib/libmtp.9.dylib ] || Vendor/build-libs.sh'
      - name: Unit tests
        run: swift test --package-path Packages/MTPKit
      - name: App build
        run: |
          xcodegen generate
          xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Debug -derivedDataPath DerivedData build | tee build.log | tail -5
          ! grep -E "warning: .*\.swift" build.log
      - name: Strings in sync
        run: |
          scripts/sync-strings.sh
          git diff --exit-code -- '*.xcstrings'
```

Runner image: the code needs the macOS 26+ SDK for Liquid Glass. If `macos-26` isn't available, use the newest `macos-*` image that ships an Xcode with SDK ≥ 26, and record which one in the report and in `docs/RELEASING.md`. UI tests are not run in CI. They need Automation Mode and take over the screen, so they stay a local pre-release step, listed in `docs/RELEASING.md`.

- [ ] **Step 3: `release.yml`**

```yaml
name: Release
on:
  push:
    tags: ['v*']
permissions:
  contents: write
jobs:
  release:
    runs-on: macos-26
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - name: Select newest Xcode
        run: sudo xcode-select -s "$(ls -d /Applications/Xcode*.app | sort -V | tail -1)"
      - run: brew install xcodegen
      - uses: actions/cache@v4
        with:
          path: Vendor/build
          key: vendor-${{ runner.os }}-${{ hashFiles('Vendor/build-libs.sh') }}
      - run: '[ -f Vendor/build/lib/libmtp.9.dylib ] || Vendor/build-libs.sh'
      - name: Version from tag
        run: |
          V="${GITHUB_REF_NAME#v}"
          [[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "tag must be vX.Y.Z" >&2; exit 1; }
          grep -q "MARKETING_VERSION: \"$V\"" project.yml || { echo "project.yml MARKETING_VERSION != $V" >&2; exit 1; }
          echo "VERSION=$V" >> "$GITHUB_ENV"
          echo "BUILD=$(git rev-list --count HEAD)" >> "$GITHUB_ENV"
      - name: Unit tests
        run: swift test --package-path Packages/MTPKit
      - name: Build DMG
        run: scripts/build-release.sh --version "$VERSION" --build "$BUILD" --out dist
      # Developer ID signing + notarization would go here (disabled: no Apple Developer Program membership).
      # When available: codesign --options runtime --timestamp -s "Developer ID Application: …" inside-out,
      # then xcrun notarytool submit --wait and xcrun stapler staple on the DMG.
      - name: EdDSA signature
        env:
          SPARKLE_ED_PRIVATE_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}
        run: |
          [ -n "$SPARKLE_ED_PRIVATE_KEY" ] || { echo "missing SPARKLE_ED_PRIVATE_KEY secret" >&2; exit 1; }
          SIGN=$(find DerivedData/release -name sign_update -path "*Sparkle*" -type f | head -1)
          SIG=$(echo "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN" --ed-key-file - -p "dist/Tether-$VERSION.dmg")
          echo "EDSIG=$SIG" >> "$GITHUB_ENV"
      - name: GitHub Release
        env: { GH_TOKEN: "${{ github.token }}" }
        run: |
          gh release create "$GITHUB_REF_NAME" "dist/Tether-$VERSION.dmg" \
            --title "Tether $VERSION" --generate-notes
      - name: Update appcast on gh-pages
        env: { GH_TOKEN: "${{ github.token }}" }
        run: |
          URL="https://github.com/${GITHUB_REPOSITORY}/releases/download/${GITHUB_REF_NAME}/Tether-${VERSION}.dmg"
          git fetch origin gh-pages:gh-pages || git branch gh-pages
          git worktree add ../pages gh-pages
          scripts/appcast.sh "dist/Tether-$VERSION.dmg" "$VERSION" "$BUILD" "$URL" "$EDSIG" ../pages/appcast.xml
          cd ../pages
          touch .nojekyll
          git add appcast.xml .nojekyll
          git -c user.name="github-actions" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
            commit -m "appcast: Tether $VERSION"
          git push origin gh-pages
```

Check `sign_update`'s real flags in the resolved Sparkle version (`sign_update --help`). The goal is to read the private key from the secret without ever writing it to a tracked file, and to print only the `edSignature` value. If `-p` doesn't exist, parse `sparkle:edSignature="…"` from the default output.

If `gh-pages` doesn't exist yet, `git branch gh-pages` creates it from HEAD. Prefer creating an orphan `gh-pages` in Task 5, so it doesn't carry the source tree.

- [ ] **Step 4: `docs/RELEASING.md`**

Document:
- **Prerequisites:**
  - the Sparkle key, and where the private half lives;
  - the `SPARKLE_ED_PRIVATE_KEY` secret;
  - Pages served from `gh-pages`.
- **Cutting a release:**
  1. Run the device checklist (`docs/testing/device-checklist.md`), the UI tests and `scripts/build-release.sh --smoke` locally.
  2. Bump `MARKETING_VERSION` in `project.yml` in a PR.
  3. Merge the PR.
  4. Tag: `git tag vX.Y.Z && git push origin vX.Y.Z`.
  5. Watch the Release workflow.
  6. Check the appcast at the Pages URL.
- **The unsigned-app note**, the README install steps, and how to enable Developer ID and notarization later: the commented hook in `release.yml`.
- **How `Credits.rtf` is regenerated.**
- **The runner image and Xcode selection.**

- [ ] **Step 5: Verify locally and commit**

Run:
- `bash -n` on both scripts;
- `scripts/test-appcast.sh`;
- `actionlint` on the workflows, if it's installable with `brew install actionlint`. If it isn't, use `ruby -ryaml -e 'YAML.load_file(ARGV[0])'` per file for syntax.

CI runs for real on the PR, because the PR triggers `ci.yml`. The controller watches that run. Release isn't exercised until Task 5.

```bash
git add .github scripts/appcast.sh scripts/test-appcast.sh docs/RELEASING.md
git commit -m "ci: build/test workflow, tag-driven release with DMG and Sparkle appcast"
```

---

### Task 5: Go public and release 1.0.0 (controller-run, maintainer-gated)

This task is **not dispatched to a subagent**. The controller runs it after the Plan 3 PR is merged, asking the maintainer for an explicit go-ahead before each outward step.

- [ ] **Step 1: Sparkle key (maintainer)**

The maintainer runs `generate_keys` in Terminal. The controller puts the public key in `project.yml` (`SPARKLE_PUBLIC_KEY`) via a small PR, or a direct commit if the maintainer prefers. The maintainer then exports the private key to a file for Step 4.

- [ ] **Step 2: Rewrite author emails (destructive; maintainer go-ahead)**

1. Confirm there are no open PRs or branches besides `main` (`gh pr list`, `git ls-remote --heads origin`).
2. Make a backup: `git clone --mirror https://github.com/r415uk3/Tether.git ~/Tether-backup-$(date +%Y%m%d).git`.
3. Rewrite in a fresh clone, then force-push `main`:
   ```
   brew install git-filter-repo
   git clone https://github.com/r415uk3/Tether.git /tmp/tether-rewrite && cd /tmp/tether-rewrite
   printf '%s\n' 'r415uk3 <119946977+r415uk3@users.noreply.github.com> <<redacted>>' > /tmp/mailmap
   git filter-repo --mailmap /tmp/mailmap
   git log --format='%ae %ce' | sort -u
   ```
   Expected: only noreply addresses, plus `noreply@github.com` for GitHub-made merge commits.
   ```
   git remote add origin https://github.com/r415uk3/Tether.git
   git push --force origin main
   ```
4. Update the working copy: `cd ~/Tether && git fetch origin && git reset --hard origin/main`. Run this only after confirming the working copy is clean.
5. Delete any stale remote branches and tags that still point at old commits.

Old commit SHAs remain reachable through the merged PR pages on GitHub (`refs/pull/*`). To purge those, GitHub Support has to run a GC. Tell the maintainer this.

- [ ] **Step 3: Make the repo public and enable Pages (maintainer go-ahead)**

1. Run `gh repo edit r415uk3/Tether --visibility public --accept-visibility-change-consequences`.
2. Create an orphan `gh-pages` branch holding only `.nojekyll` and an `index.html` that links to Releases. Push it.
3. Enable Pages from `gh-pages` / root: `gh api -X POST repos/r415uk3/Tether/pages -f "source[branch]=gh-pages" -f "source[path]=/"`.
4. Check that `https://r415uk3.github.io/Tether/` serves.

- [ ] **Step 4: Secret (maintainer)**

1. Run `gh secret set SPARKLE_ED_PRIVATE_KEY < sparkle_private_key.txt`. The maintainer can run it via `!`, or in their own Terminal.
2. Delete the file afterwards.
3. Confirm with `gh secret list`.

- [ ] **Step 5: Tag 1.0.0 (maintainer go-ahead)**

1. On an up-to-date `main` with `MARKETING_VERSION: "1.0.0"`, run `git tag v1.0.0 && git push origin v1.0.0`.
2. Watch the run: `gh run watch`.
3. Verify:
   - The Release `v1.0.0` has `Tether-1.0.0.dmg`.
   - `curl -s https://r415uk3.github.io/Tether/appcast.xml` shows the item, with `sparkle:version` equal to the build and a non-empty `edSignature`.
   - Download the DMG with a browser, so it is quarantined. Install it per the README ("Open Anyway"). The app launches, and About shows the icon and credits.
4. If the workflow fails, fix it forward with a PR, delete the tag and the Release, and re-tag. Never edit a published DMG in place.

---

## Spec coverage

| Spec / decision | Task |
|---|---|
| §2 MIT licence; LGPL texts and source links in About/Acknowledgements | 1 |
| §2 Sparkle (SPM) | 3 |
| §2 Universal arm64 + x86_64 | 2 |
| §7 CI: build + unit tests on every PR | 4 |
| §7 Tagged releases: build, create DMG, update the Sparkle appcast | 4, 5 |
| §7 "sign, notarize": deferred (no Developer ID), with a disabled hook in `release.yml` | 4 (documented) |
| Public free release (brainstorm decision B) | 5 |
| Maintainer decisions: unsigned, public repo, 1.0.0, email rewrite, placeholder icon | 1–5 |
