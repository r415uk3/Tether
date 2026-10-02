# Releasing Tether

Releases are tag-driven: pushing `vX.Y.Z` runs `.github/workflows/release.yml`, which builds the universal
ad-hoc-signed DMG, signs it with the Sparkle EdDSA key, creates the GitHub Release and prepends an item to
`appcast.xml` on the `gh-pages` branch. Installed copies pick it up through Sparkle.

## Prerequisites

- **Sparkle key pair.** The private half lives only in the maintainer's login keychain and in the
  `SPARKLE_ED_PRIVATE_KEY` GitHub Actions secret. It is never committed. The public half is
  `SPARKLE_PUBLIC_KEY` in `project.yml` (injected as `SUPublicEDKey`). **It is a placeholder
  (`REPLACE_IN_TASK_5`) until the real key is generated and committed in Task 5.**
- **Generate the real key** (once, on the maintainer's Mac). Find the tools in the resolved Sparkle package:
  `find DerivedData -name generate_keys -path "*Sparkle*"`.

  ```bash
  GK=path/to/generate_keys
  "$GK"                 # creates the key in the keychain, prints the public key
  "$GK" -p              # print the public key again later
  "$GK" -x /secure/tmp/sparkle_private_key   # export the private key to a file
  ```

  Put the public key into `project.yml` (`SPARKLE_PUBLIC_KEY`). Load the exported file into the secret
  (`gh secret set SPARKLE_ED_PRIVATE_KEY < /secure/tmp/sparkle_private_key`), then delete the file.
  Changing the key later breaks updates for every installed copy, so keep a backup of the export offline.
- **Export format (confirmed).** For keys in the current format, `generate_keys -x` writes the base64 encoding
  of the 32-byte Ed25519 seed (per its `--help`). `sign_update --ed-key-file <file>` (`-f`) takes exactly that, and
  `--ed-key-file -` reads it from stdin, which is how the workflow passes the secret without touching disk.
  This was verified with a throwaway key made by `openssl rand -base64 32`: `sign_update -p` produced an
  88-character signature, `--verify` accepted it, and file and stdin modes gave identical output.
- **GitHub Pages** is served from the `gh-pages` branch (Settings → Pages), so the feed URL is
  `https://r415uk3.github.io/Tether/appcast.xml`. Prefer an orphan `gh-pages` branch, so it does not carry
  the source tree. The workflow falls back to a branch created from HEAD if none exists.

## Cutting a release

1. Locally, run the device checklist (`docs/testing/device-checklist.md`), the UI tests (they need Automation
   Mode and take over the screen, so they are not run in CI), and `scripts/build-release.sh --smoke`.
2. Bump `MARKETING_VERSION` in `project.yml` in a PR.
3. Merge the PR.
4. Tag: `git tag vX.Y.Z && git push origin vX.Y.Z`. The tag must match `MARKETING_VERSION`, or the workflow
   fails early.
5. Watch the Release workflow. The build number is `git rev-list --count HEAD` (hence `fetch-depth: 0`) and must
   exceed every build already in the appcast, or `scripts/appcast.sh` refuses.
6. Check the appcast at the Pages URL and that the DMG is attached to the GitHub Release.

`scripts/appcast.sh` and its test (`scripts/test-appcast.sh`, also run in CI) can be used by hand:
`scripts/appcast.sh <dmg> <version> <build> <download-url> <ed-signature> <appcast.xml>`.

## Unsigned app (no Developer ID)

Tether is ad-hoc signed and not notarized, because there is no Apple Developer Program membership. Users
install by opening the DMG, dragging Tether to Applications, launching it once, then going to
System Settings → Privacy & Security and clicking **Open Anyway** (see the README install steps).

Because ad-hoc signatures carry no Team ID, both **MTPHelper** and the **app** have the entitlement
`com.apple.security.cs.disable-library-validation` (`MTPHelper/MTPHelper.entitlements` and
`Tether/Tether.entitlements`), so they can load the bundled libmtp/libusb and Sparkle. **Remove it from both
once a Developer ID exists**, and sign with the hardened runtime.

To enable Developer ID signing and notarization later, use the commented hook in `release.yml` (after
"Build DMG", before "EdDSA signature"): `codesign --options runtime --timestamp -s "Developer ID Application: …"`
inside-out, then `xcrun notarytool submit --wait` and `xcrun stapler staple` on the DMG. Sign the DMG with
EdDSA after stapling, since stapling changes the file.

## Credits.rtf

`Tether/Resources/Credits.rtf` is generated, not hand-edited. Edit the text in `scripts/credits/*.txt`
(`sparkle-license.txt` is `LICENSE` from the resolved Sparkle package, `lgpl-2.1.txt` is `COPYING` from the
libmtp tarball) and run `scripts/make-credits.sh`, then commit the result.

## Runner image and Xcode

Both workflows use `runs-on: macos-26`, because the code needs the macOS 26 SDK (Liquid Glass). Each job
selects the newest installed Xcode (`ls -d /Applications/Xcode*.app | sort -V | tail -1`) with
`sudo xcode-select -s`; CI also prints `xcodebuild -version` and the SDK version. If `macos-26` is
unavailable, switch to the newest `macos-*` image whose Xcode ships SDK 26 or later and record it here.
The native libs (`Vendor/build`) are cached on the hash of `Vendor/build-libs.sh`.
