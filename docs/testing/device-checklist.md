# Real-device checklist

Run before each release with at least a Pixel, a Samsung and a Xiaomi phone. Note the phone, Android version and Tether build next to each result.

## Connection
- [ ] Plug in an unlocked phone set to "File transfer": it appears in the sidebar with its storages within 5 s.
- [ ] Plug in a locked phone: "Unlock …" shows; unlocking connects without clicking anything.
- [ ] Plug in a phone set to "Charging only": the device shows the locked/USB-mode guidance, not an error.
- [ ] Two phones at once: both appear; browsing one doesn't block the other.
- [ ] Launch Tether with no phone: the connection guide appears (no endless spinner).

## Image Capture (Release)
- [ ] Open Image Capture, plug in the phone: Tether shows "Another App Is Using …" with Release.
- [ ] Press Release: the phone becomes browsable within 3 s. Repeat 3 times; note any "Still held" results.
- [ ] Check that macOS doesn't relaunch ptpcamerad and re-grab the phone within 10 s after Release.
- [ ] Without pressing Release, Tether never quits Image Capture on its own (leave it open for 1 minute).

## Transfers
- [ ] Download a file larger than 4 GB; compare its size and checksum with the phone's copy.
- [ ] Upload a file larger than 4 GB.
- [ ] Unplug mid-download: the job fails with Retry; no `.partial` file remains in the download folder.
- [ ] Unplug mid-upload, replug: the job fails; the phone has no incomplete file; the job shows no Retry.
- [ ] Quick Look a large video, close it before it finishes: "Preparing preview…" disappears.

## Diagnostics and language
- [ ] Help → Copy Diagnostics: paste into a text editor; versions and phone model are listed; no file names or serials appear.
- [ ] Switch macOS to Russian (or launch with `-AppleLanguages "(ru)"`): the whole UI is Russian, with no clipped text in the sidebar, toolbar or dialogs.
- [ ] VoiceOver (⌘F5): navigate the sidebar, the file list and the transfers popover; every control and file is announced with a meaningful name.
