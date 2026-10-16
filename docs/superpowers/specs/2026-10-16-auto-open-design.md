# Auto-open Tether when a phone connects

## Intent

Today, using Tether starts with an extra step: you plug in the phone, choose **File transfer**, and then have to open Tether yourself. The user wants that step gone. Plugging in an Android phone in File transfer mode should bring Tether to the front, the way Image Capture opens for cameras.

Success: plug in, pick File transfer on the phone, and the Tether window is in front of you showing that phone, with no clicks on the Mac.

## Goals

- When an Android phone **in File transfer (MTP) mode** connects, Tether launches, or comes to the front if it's already running, and **takes focus**.
- It works even when Tether isn't running. This needs a small background helper that starts at login.
- The helper is **light**: event-driven with no polling, no CPU while idle, and a few MB of memory. (User: "if it doesn't consume too much resources".)
- **Off by default.** A Settings toggle turns it on and off.

## Non-goals

- Picking which folder opens, or auto-copying anything. This feature only gets the window up.
- Stopping Image Capture or Photos from also opening. Tether's existing **Release** button covers that clash.
- Changing how the existing `MTPHelper` XPC service finds and talks to phones.

## Anti-goals (failure even if it "works")

- A noticeable background cost: polling timers, waking the CPU, loading libmtp/libusb in the background helper.
- Tether opening when the phone is **only charging**, or reopening by itself after the user quit it.
- The helper claiming the USB device in a way that gets in the way of `MTPHelper`, Image Capture or Photos. It should only look at USB descriptors, never open the device.

## Behaviour

| Situation | What happens |
|---|---|
| Phone connects in File transfer mode, Tether not running | Tether launches and comes to the front. |
| Same, Tether running with its window open | Tether comes to the front. The new phone is selected in the sidebar. |
| Same, Tether running but window closed or minimized | The main window reopens or unminimizes and comes to the front. |
| Phone connects charging-only | Nothing. When the user picks File transfer, the phone re-enumerates on USB as a new device with an MTP interface, and that arrival triggers the open. |
| Phone connects locked but already in File transfer mode | Tether opens and shows its existing "Unlock your phone" state, then connects when the phone is unlocked *(my call: a locked MTP phone looks identical at descriptor level, and the unlock prompt is useful)*. |
| Phone re-appears on USB without a deliberate plug-in (Mac wakes from sleep, dock/hub reconnects, some phones re-enumerate on unlock) | Nothing *(my call)*. Ignore arrivals for ~10 s after a wake notification, and ignore an MTP device whose serial (or locationID if no serial) left less than ~1 s ago. (First set to ~5 s; the real-phone test showed a hand replug takes 1.7–2 s while connection glitches come back in ~0.2 s, so 5 s swallowed every deliberate replug.) A charging-only → File transfer switch still triggers, because the earlier enumeration had no MTP interface. |
| User quits Tether while the phone stays connected | Tether stays closed. Only a *new* arrival opens it again (unplug/replug, or a mode switch that re-enumerates). |
| Phone already connected at login, or when the toggle is switched on | Nothing *(my call)*. Only arrivals after the helper starts count. |
| Toggle off | The login item is unregistered and the helper stops. Nothing runs in the background. |

## How (decided)

- **Separate login-item helper**, a new target (working name `TetherLauncher`). It's a tiny background-only executable (`LSUIElement`/`LSBackgroundOnly`, no Dock icon, no menu bar icon *(my call: the user asked for nothing visible)*) embedded at `Tether.app/Contents/Library/LoginItems/`. Tether registers and unregisters it with `SMAppService.loginItem(identifier:)` from the Settings toggle.
- **Detection uses IOKit notifications**, the same mechanism as `MTPHelper/USBWatcher.swift`: `IOServiceAddMatchingNotification` for `kIOFirstMatchNotification`, delivered on the main run loop/queue. No timers.
- **"File transfer mode" check reads descriptors only.** On each new device, look at its `IOUSBHostInterface` children for an MTP interface. Android's is usually class `0xFF`, subclass `0xFF`, protocol `0`, with interface string `"MTP"`. Only MTP counts *(my call)*: the still-image/PTP class `0x06/0x01/0x01` alone does **not** trigger, because iPhones and cameras expose it too. Accept a `0x06` interface only if its interface string contains "MTP". Don't open the device and don't link libmtp/libusb.
- **Launching:** `NSWorkspace.shared.openApplication(at:configuration:)` on the containing `Tether.app` with `activates = true`. Find the app bundle relative to the helper's own location (`../../../..` from the helper bundle), not by bundle ID, so the copy that registered the helper is the one that opens.
- **Settings:** a new toggle in `Tether/SettingsView.swift`, *"Open Tether when a phone connects"*, plus a Russian string in the catalogs. The toggle shows the real `SMAppService.status` rather than a stored bool, so it can't drift from reality. If status is `.requiresApproval`, show a short note with a button that calls `SMAppService.openSystemSettingsLoginItems()`.

## Spike results (2026-10-16, ad-hoc signed, hardened runtime, macOS 27)

A throwaway host and login-item helper built with `swiftc` and `codesign -s -`, registered with `SMAppService.loginItem`:

- **Registration works without a Developer ID.** Status goes straight to `.enabled` with no approval needed. Turning it on for the first time shows the system's one-time "background item added" notification.
- **Idle cost:** 7–10 MB RSS and 0% CPU, with an IOKit `kIOFirstMatchNotification` watcher armed.
- **After an update the helper silently breaks.** Swapping in a newly signed bundle leaves `SMAppService.status == .enabled`, but launchd refuses to spawn it (`spawn failed`). The log shows either `copy_bundle_path(...) Invalid or missing Program/ProgramArguments` or `Unable to get updated LWCR ... Invalid argument`. Without a fix, auto-open stops working after every Sparkle update with no visible error.
- **Fix that worked:** on the first launch of a new build (compare `CFBundleVersion` with a stored "registered for build" value), call `unregister()`, **wait until launchd has dropped the job** (poll `status` / a short delay; registering again immediately reproduced the stale-LWCR failure), then `register()`. The new helper starts and the old one is gone. **No notification appears on this re-registration.** The app must have been opened through LaunchServices (normal launch or Sparkle relaunch), not by running the binary directly.
- **Real phone (vivo iQOO Z10 Turbo Pro, VID 0x2D95, USB debugging on):** charging-only exposes just `255/66/1` "ADB Interface", so no trigger. Switching to File transfer re-enumerates the device as a new arrival with `6/1/1` "MTP", `8/6/80` "Mass Storage" and `255/66/1` "ADB Interface". So this phone uses the still-image class **with** the "MTP" name, which the matching rule above accepts. The interface name lives in the IORegistry key **`kUSBString`**, not `USB Interface Name`. The interfaces were present 1.5 s after the device-arrival notification. Match on interface arrival (`IOUSBHostInterface`) or wait briefly, rather than reading children at the instant the device appears.
- Not tested in the spike: surviving a reboot, a real Sparkle install, or descriptor matching against a real phone. Cover these in the device checklist.

## Constraints

- macOS 15+, Swift 6, XcodeGen (`project.yml`). The app is **ad-hoc signed and not notarized**, with hardened runtime and no sandbox. The helper must be signed the same way and embedded so `SMAppService` accepts it. Verify this on a real ad-hoc build early, because it's the riskiest assumption.
- Sparkle replaces the app bundle on update. The registered login item must keep working afterwards, and the newly installed helper should be the one that runs. Use the re-register-on-new-build step from the spike. While the toggle is on, also re-check on every launch that the helper is actually running, and re-register if launchd reports a failed spawn.
- English and Russian for every new user-facing string (`scripts/sync-strings.sh`, localization tests).
- The `-UseFakeDevices` / UI test setup must never register a real login item. The toggle is hidden in that mode *(my call)*, so no UI test covers it.

## Left to the builder

- Exact target name, file layout, and how much detection code to share with `USBWatcher` (sharing is fine if the helper doesn't pull in libmtp).
- How Tether selects the newly arrived phone and reopens a closed window. A reopen Apple Event from `openApplication`, or an explicit handler in the app, both work if they meet the behaviour table.
- Debouncing. A phone can show up as several USB devices in quick succession, and the user should see one activation.
- Tests: unit-test the descriptor matching (MTP / PTP / charging-only / non-phone) against fake descriptor data. Add a manual row to `docs/testing/device-checklist.md` for the real plug-in flow.
