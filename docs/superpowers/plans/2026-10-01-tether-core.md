# Tether Core (Plan 1 of 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A working Tether app that lists connected Android phones, browses their folders, downloads by dragging files to Finder, and uploads by dropping files into the window. All USB work runs in a crash-isolated XPC helper.

**Architecture:** A SwiftUI app (`Tether`) talks over XPC to an embedded helper (`MTPHelper.xpc`) that owns libmtp. Device-agnostic logic (models, the per-device worker thread, transfer algorithms, the service engine, the XPC codec) lives in the `MTPKit` Swift package and is unit-tested against an in-memory `FakeDevice`. App state (`DeviceStore`, `TransferQueue`, `AppModel`) lives in a second package library, `TetherCore`, so it is testable with `swift test` without launching the app.

**Tech Stack:** Swift 6.0 language mode (Xcode 27 / Swift 6.4 toolchain), SwiftUI + AppKit (`NSTableView`, `NSFilePromiseProvider`), Swift Testing, NSXPCConnection, libmtp 1.1.23 + libusb 1.0.30 (built from source, dynamically linked), XcodeGen 2.46.

**Spec:** `docs/superpowers/specs/2026-10-01-tether-design.md`

**Plan series:**
- **Plan 1 (this):** core engine and a usable minimal window.
- **Plan 2:** full UX:
  - icon view and thumbnails
  - Quick Look
  - rename, delete and new folder UI
  - conflict dialog
  - Settings
  - empty and error states
  - Image Capture detection and release
  - menus and shortcuts
  - English and Russian String Catalog
  - VoiceOver
  - UI tests
  - Liquid Glass polish
- **Plan 3:** distribution:
  - Developer ID signing and notarization
  - Sparkle
  - DMG
  - GitHub Actions
  - Acknowledgements
  - real-device checklist

**Deliberate deviation from the spec:** spec §9 risk 1 asks for a drag-out spike to choose between SwiftUI and AppKit for the file view. This plan resolves it up front by using AppKit (`NSTableView` + `NSFilePromiseProvider`). That path is known to support file promises, multi-select and inline rename, and it costs roughly one file.

## Global Constraints

- Minimum macOS: **15.0** (`MACOSX_DEPLOYMENT_TARGET = 15.0`, `platforms: [.macOS(.v15)]`). Native libraries must also be built with `-mmacosx-version-min=15.0`.
- Swift language mode **6** with strict concurrency; no `@preconcurrency` imports. Use `Unchecked<T>` (Task 3) for the few AppKit/XPC values that cross isolation.
- Architectures: universal (arm64 + x86_64) for the app and both dylibs.
- libmtp / libusb are LGPL-2.1. Link them **dynamically** and embed them in `MTPHelper.xpc/Contents/Frameworks`. Never link statically.
- Bundle IDs: app `dev.tether.Tether`, helper `dev.tether.Tether.MTPHelper` (the XPC service name).
- File sizes and byte counts are always `UInt64`. Never `Int32`/`UInt32`.
- MTP root folder ID is `0xFFFFFFFF` (`FileEntry.rootID`) for listing. When creating or uploading into root, pass parent `0` to libmtp.
- User-facing strings use `String(localized:)` / `LocalizedStringKey` so Plan 2 can extract them into a String Catalog.
- The Xcode project is generated: `project.yml` is the source of truth, and `Tether.xcodeproj` is git-ignored.
- Development signing is ad-hoc (`CODE_SIGN_IDENTITY = "-"`) with Hardened Runtime on.

## Review Focus

1. **Phone file names that are unsafe on macOS** (`..`, `.`, names containing `/`, empty names): downloads must be sanitized and never escape the destination folder. Pinned in Task 6, `sanitizesUnsafeNames`.
2. **Files larger than 4 GB:** sizes must survive XPC encoding, and the free-space check must use 64-bit math. Pinned in Task 3, `fileEntryRoundTripsLargeSize`, and Task 7, `rejectsFiveGigabyteFileWhenFourAreFree` (sparse file).
3. **Downloading where a file of the same name exists**, or two downloads of the same name at once: Tether must pick "name 2", never overwrite, and never collide with another in-progress `.partial`. Pinned in Task 6, `keepsExistingFiles` and `avoidsNamesOfInProgressDownloads`.
4. **Phone unplugged while an operation is in flight:** the operation fails with `.deviceDisconnected`, the device and its listings disappear, and nothing hangs. Pinned in Task 8, `detachFailsInFlightOperation`, and Task 11, `removedDeviceDropsListings`.
5. **Cancel pressed before a queued job reaches the phone:** no bytes are transferred and no partial file is left. Pinned in Task 8, `cancelBeforeStartSkipsTransfer`, and Task 12, `cancelQueuedJob`.

---

## File Structure

```
Tether/
  project.yml                         # XcodeGen spec (Task 2)
  README.md                           # build instructions (Task 2)
  .gitignore                          # (Task 2)
  Vendor/
    build-libs.sh                     # builds universal libusb + libmtp (Task 1)
    CLibMTP/module.modulemap          # Swift module for libmtp (Task 1)
    CLibMTP/shim.h                    # (Task 1)
  Packages/MTPKit/
    Package.swift                     # libraries MTPKit + TetherCore (Task 2)
    Sources/MTPKit/
      Models.swift                    # DeviceInfo, StorageInfo, FileEntry, FolderRef (Task 3)
      MTPError.swift                  # typed errors + messages (Task 3)
      Concurrency.swift               # Unchecked, OnceContinuation, LockedFlag, withTimeout (Task 3)
      MTPDevice.swift                 # MTPDevice + DeviceProvider protocols (Task 4)
      FakeDevice.swift                # in-memory device with fault injection (Task 4)
      FakeDeviceProvider.swift        # fake attach/detach + demo data (Task 4)
      DeviceWorker.swift              # one thread per device, priority queue (Task 5)
      Transfers+Download.swift        # partial-file download, naming (Task 6)
      Transfers+Upload.swift          # free space, conflicts, tree upload, cleanup (Task 7)
      MTPService.swift                # MTPService protocol + ServiceEvent (Task 8)
      LocalMTPService.swift           # the engine: rescan, workers, jobs (Task 8)
      XPC/XPCMessages.swift           # @objc protocols, request/response, codec (Task 9)
      XPC/MTPXPCEndpoint.swift        # helper side (Task 9)
      XPC/XPCMTPService.swift         # app side client (Task 9)
    Sources/TetherCore/
      DeviceStore.swift               # devices, storages, cached listings (Task 11)
      TransferQueue.swift             # jobs, per-device serial, watchdog (Task 12)
      AppModel.swift                  # wires events to the stores (Task 12)
    Tests/MTPKitTests/ ...            # one file per unit (Tasks 3–9)
    Tests/TetherCoreTests/ ...        # (Tasks 11–12)
  MTPHelper/
    main.swift                        # XPC listener + rescan wiring (Task 10)
    LibMTPDevice.swift                # MTPDevice over libmtp (Task 10)
    LibMTPProvider.swift              # device detection/open (Task 10)
    USBWatcher.swift                  # IOKit plug/unplug notifications (Task 10)
  Tether/
    TetherApp.swift                   # app entry, service choice (Task 2 stub → Task 13)
    ContentView.swift                 # split view + selection (Task 13)
    SidebarView.swift                 # devices + storages (Task 13)
    BrowserView.swift                 # folder browsing, toolbar (Task 13)
    FileTableView.swift               # NSTableView bridge, drag in/out (Task 13)
    FilePromise.swift                 # NSFilePromiseProvider delegate (Task 13)
    TransfersPopover.swift            # transfer list (Task 13)
```

Every command below runs from the repo root `~/Tether` unless it says otherwise.

---

### Task 1: Universal libusb + libmtp build

**Files:**
- Create: `Vendor/build-libs.sh`
- Create: `Vendor/CLibMTP/module.modulemap`
- Create: `Vendor/CLibMTP/shim.h`

**Interfaces:**
- Produces:
  - `Vendor/build/lib/libmtp.9.dylib` and `Vendor/build/lib/libusb-1.0.0.dylib`: universal, minos 15.0, install names `@rpath/...`
  - `Vendor/build/include/libmtp.h`
  - Swift module `CLibMTP`

Notes, both found while prototyping this plan:
- libusb's configure script detects `pipe2`, which the macOS 27 SDK declares as **macOS 27-only**. Left alone, the helper would fail to load on macOS 15. We force `ac_cv_func_pipe2=no`.
- libmtp's configure script insists on `pkg-config`. We pass `LIBUSB_CFLAGS`/`LIBUSB_LIBS` directly and set `PKG_CONFIG=/usr/bin/true`, so no extra tool is needed.

- [ ] **Step 1: Write the build script**

`Vendor/build-libs.sh`:

```bash
#!/bin/bash
# Builds universal (arm64 + x86_64) libusb and libmtp dylibs for MTPHelper.xpc.
# Output: Vendor/build/{lib,include}. Safe to re-run; downloads are cached in Vendor/.cache.
set -euo pipefail

LIBUSB_VERSION=1.0.30
LIBUSB_SHA256=fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf
LIBMTP_VERSION=1.1.23
LIBMTP_SHA256=74a2b6e8cb4a0304e95b995496ea3ac644c29371649b892b856e22f12a0bdeed
MIN_MACOS=15.0

HERE="$(cd "$(dirname "$0")" && pwd)"
CACHE="$HERE/.cache"
WORK="$HERE/.work"
OUT="$HERE/build"

fetch() { # url sha256 file
  local url="$1" sum="$2" file="$CACHE/$3"
  mkdir -p "$CACHE"
  [ -f "$file" ] || curl -fsSL -o "$file" "$url"
  echo "${sum}  ${file}" | shasum -a 256 -c - >/dev/null || { echo "error: checksum mismatch for $file" >&2; exit 1; }
}

fetch "https://github.com/libusb/libusb/releases/download/v${LIBUSB_VERSION}/libusb-${LIBUSB_VERSION}.tar.bz2" "$LIBUSB_SHA256" "libusb-${LIBUSB_VERSION}.tar.bz2"
fetch "https://github.com/libmtp/libmtp/releases/download/v${LIBMTP_VERSION}/libmtp-${LIBMTP_VERSION}.tar.gz" "$LIBMTP_SHA256" "libmtp-${LIBMTP_VERSION}.tar.gz"

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT/lib" "$OUT/include"

for ARCH in arm64 x86_64; do
  P="$WORK/$ARCH"
  mkdir -p "$P/src"
  if [ "$ARCH" = arm64 ]; then HOST=aarch64-apple-darwin; else HOST=x86_64-apple-darwin; fi
  export CFLAGS="-arch $ARCH -mmacosx-version-min=$MIN_MACOS -O2"
  export LDFLAGS="-arch $ARCH -mmacosx-version-min=$MIN_MACOS"

  tar xf "$CACHE/libusb-${LIBUSB_VERSION}.tar.bz2" -C "$P/src"
  # pipe2 is macOS 27+ in the current SDK; using it would break launch on macOS 15.
  (cd "$P/src/libusb-${LIBUSB_VERSION}" &&
    ac_cv_func_pipe2=no ./configure --host="$HOST" --prefix="$P/prefix" --disable-static >/dev/null &&
    make -j"$(sysctl -n hw.ncpu)" >/dev/null && make install >/dev/null)

  tar xf "$CACHE/libmtp-${LIBMTP_VERSION}.tar.gz" -C "$P/src"
  # libmtp's configure demands pkg-config; giving LIBUSB_* directly makes it unnecessary.
  (cd "$P/src/libmtp-${LIBMTP_VERSION}" &&
    LIBUSB_CFLAGS="-I$P/prefix/include/libusb-1.0" LIBUSB_LIBS="-L$P/prefix/lib -lusb-1.0" PKG_CONFIG=/usr/bin/true \
    ./configure --host="$HOST" --prefix="$P/prefix" --disable-static --disable-mtpz --without-udev >/dev/null &&
    make -j"$(sysctl -n hw.ncpu)" -C src >/dev/null && make -C src install >/dev/null)

  L="$P/prefix/lib"
  install_name_tool -id @rpath/libusb-1.0.0.dylib "$L/libusb-1.0.0.dylib"
  install_name_tool -id @rpath/libmtp.9.dylib "$L/libmtp.9.dylib"
  install_name_tool -change "$L/libusb-1.0.0.dylib" @rpath/libusb-1.0.0.dylib "$L/libmtp.9.dylib"
done

lipo -create "$WORK"/{arm64,x86_64}/prefix/lib/libusb-1.0.0.dylib -output "$OUT/lib/libusb-1.0.0.dylib"
lipo -create "$WORK"/{arm64,x86_64}/prefix/lib/libmtp.9.dylib -output "$OUT/lib/libmtp.9.dylib"
ln -sf libmtp.9.dylib "$OUT/lib/libmtp.dylib"
cp "$WORK/arm64/prefix/include/libmtp.h" "$OUT/include/"

if nm -u "$OUT/lib/libusb-1.0.0.dylib" | grep -q '_pipe2$'; then
  echo "error: libusb references pipe2 (macOS 27+)" >&2; exit 1
fi
echo "Built:"; lipo -info "$OUT/lib/libusb-1.0.0.dylib" "$OUT/lib/libmtp.9.dylib"
```

- [ ] **Step 2: Write the Swift module map**

`Vendor/CLibMTP/shim.h`:

```c
#include "../build/include/libmtp.h"
```

`Vendor/CLibMTP/module.modulemap`:

```
module CLibMTP [system] {
  header "shim.h"
  link "mtp"
  export *
}
```

- [ ] **Step 3: Run the build**

Run: `chmod +x Vendor/build-libs.sh && Vendor/build-libs.sh`
Expected: ends with `Built:` and two lines `Architectures in the fat file: ... are: x86_64 arm64`. Takes 1–3 minutes.

- [ ] **Step 4: Verify install names and minimum OS**

Run: `otool -L Vendor/build/lib/libmtp.9.dylib | grep rpath && otool -l Vendor/build/lib/libmtp.9.dylib | grep minos`
Expected: `@rpath/libmtp.9.dylib` and `@rpath/libusb-1.0.0.dylib` appear (for both architectures), and every `minos` line reads `15.0`.

- [ ] **Step 5: Commit** (build output is ignored via Task 2's `.gitignore`; until then add files explicitly)

```bash
git add Vendor/build-libs.sh Vendor/CLibMTP
git commit -m "build: universal libusb + libmtp build script and CLibMTP module"
```

---

### Task 2: Project scaffold (XcodeGen, package, app + helper stubs)

**Files:**
- Create: `project.yml`, `.gitignore`, `README.md`
- Create: `Packages/MTPKit/Package.swift`
- Create: `Packages/MTPKit/Sources/MTPKit/MTPKit.swift`, `Packages/MTPKit/Sources/TetherCore/TetherCore.swift` (placeholders, deleted in Tasks 3/11)
- Create: `Packages/MTPKit/Tests/MTPKitTests/ScaffoldTests.swift`, `Packages/MTPKit/Tests/TetherCoreTests/ScaffoldTests.swift` (deleted later)
- Create: `Tether/TetherApp.swift`, `MTPHelper/main.swift` (stubs)

**Interfaces:**
- Consumes: `Vendor/build/lib/*.dylib`, `Vendor/CLibMTP` (Task 1)
- Produces:
  - targets `Tether` (app) and `MTPHelper` (xpc-service, embedded in `Tether.app/Contents/XPCServices`)
  - package products `MTPKit` and `TetherCore`
  - constant `MTPHelperConstants.serviceName == "dev.tether.Tether.MTPHelper"`

- [ ] **Step 1: Install XcodeGen**

Run: `brew install xcodegen && xcodegen --version`
Expected: `Version: 2.46.0` (or newer)

- [ ] **Step 2: Write `.gitignore`**

```
.DS_Store
Tether.xcodeproj/
DerivedData/
.build/
.swiftpm/
Vendor/build/
Vendor/.cache/
Vendor/.work/
```

- [ ] **Step 3: Write `Packages/MTPKit/Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MTPKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MTPKit", targets: ["MTPKit"]),
        .library(name: "TetherCore", targets: ["TetherCore"]),
    ],
    targets: [
        .target(name: "MTPKit"),
        .target(name: "TetherCore", dependencies: ["MTPKit"]),
        .testTarget(name: "MTPKitTests", dependencies: ["MTPKit"]),
        .testTarget(name: "TetherCoreTests", dependencies: ["TetherCore", "MTPKit"]),
    ]
)
```

- [ ] **Step 4: Write placeholder sources and a scaffold test**

`Packages/MTPKit/Sources/MTPKit/MTPKit.swift`:

```swift
public enum MTPHelperConstants {
    /// Bundle ID of MTPHelper.xpc; also its XPC service name.
    public static let serviceName = "dev.tether.Tether.MTPHelper"
}
```

`Packages/MTPKit/Sources/TetherCore/TetherCore.swift`:

```swift
import MTPKit
```

`Packages/MTPKit/Tests/MTPKitTests/ScaffoldTests.swift`:

```swift
import Testing
@testable import MTPKit

@Test func serviceNameMatchesHelperBundleID() {
    #expect(MTPHelperConstants.serviceName == "dev.tether.Tether.MTPHelper")
}
```

`Packages/MTPKit/Tests/TetherCoreTests/ScaffoldTests.swift`:

```swift
import Testing
@testable import TetherCore

@Test func scaffold() {
    #expect(Bool(true))
}
```

- [ ] **Step 5: Run package tests**

Run: `swift test --package-path Packages/MTPKit`
Expected: `Test run with 2 tests ... passed`

- [ ] **Step 6: Write `project.yml`**

```yaml
name: Tether
options:
  bundleIdPrefix: dev.tether
  deploymentTarget:
    macOS: "15.0"
  createIntermediateGroups: true
settings:
  base:
    SWIFT_VERSION: "6.0"
    MACOSX_DEPLOYMENT_TARGET: "15.0"
    ENABLE_HARDENED_RUNTIME: YES
    CODE_SIGN_IDENTITY: "-"
    CODE_SIGN_STYLE: Manual
    DEVELOPMENT_TEAM: ""
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
packages:
  MTPKit:
    path: Packages/MTPKit
targets:
  Tether:
    type: application
    platform: macOS
    sources: [Tether]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.tether.Tether
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_CFBundleDisplayName: Tether
        INFOPLIST_KEY_LSApplicationCategoryType: public.app-category.utilities
    dependencies:
      - package: MTPKit
        product: MTPKit
      - package: MTPKit
        product: TetherCore
      - target: MTPHelper
  MTPHelper:
    type: xpc-service
    platform: macOS
    sources: [MTPHelper]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.tether.Tether.MTPHelper
        PRODUCT_NAME: MTPHelper
        GENERATE_INFOPLIST_FILE: YES
        SWIFT_INCLUDE_PATHS: $(SRCROOT)/Vendor/CLibMTP
        LIBRARY_SEARCH_PATHS: $(SRCROOT)/Vendor/build/lib
        LD_RUNPATH_SEARCH_PATHS: "@executable_path/../Frameworks"
    info:
      path: MTPHelper/Info.plist
      properties:
        XPCService:
          ServiceType: Application
    dependencies:
      - package: MTPKit
        product: MTPKit
      - framework: Vendor/build/lib/libmtp.9.dylib
        embed: true
        codeSign: true
      - framework: Vendor/build/lib/libusb-1.0.0.dylib
        embed: true
        codeSign: true
schemes:
  Tether:
    build:
      targets:
        Tether: all
```

XcodeGen writes `MTPHelper/Info.plist` from `info.properties` on every `xcodegen generate`. Commit it anyway, so fresh clones have the file.

- [ ] **Step 7: Write app and helper stubs**

`Tether/TetherApp.swift`:

```swift
import SwiftUI

@main
struct TetherApp: App {
    var body: some Scene {
        Window("Tether", id: "main") {
            Text("Tether")
                .frame(minWidth: 720, minHeight: 420)
        }
    }
}
```

`MTPHelper/main.swift`:

```swift
import Foundation
import CLibMTP
import MTPKit

LIBMTP_Init()
let listener = NSXPCListener.service()
listener.resume() // never returns
```

- [ ] **Step 8: Write `README.md`**

````markdown
# Tether

A native macOS app for transferring files to and from Android phones over USB (MTP).

## Build

Requirements: Xcode 27+, Homebrew.

```bash
brew install xcodegen
Vendor/build-libs.sh          # once; builds universal libusb + libmtp into Vendor/build
xcodegen generate             # creates Tether.xcodeproj from project.yml
open Tether.xcodeproj
```

Run with fake phones (no hardware needed): add the launch argument `-UseFakeDevices YES`
to the Tether scheme, or run
`DerivedData/Build/Products/Debug/Tether.app/Contents/MacOS/Tether -UseFakeDevices YES`.

## Tests

```bash
swift test --package-path Packages/MTPKit
```

## License

MIT. Bundles libmtp and libusb (LGPL-2.1), dynamically linked.
````

- [ ] **Step 9: Generate and build**

Run: `xcodegen generate && xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Debug -derivedDataPath DerivedData build 2>&1 | tail -1`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 10: Verify bundle layout**

Run: `ls DerivedData/Build/Products/Debug/Tether.app/Contents/XPCServices/MTPHelper.xpc/Contents/Frameworks`
Expected: `libmtp.9.dylib  libusb-1.0.0.dylib`

- [ ] **Step 11: Commit**

```bash
git add .gitignore README.md project.yml Packages Tether MTPHelper
git commit -m "build: XcodeGen project with app, XPC helper and MTPKit package"
```

---

### Task 3: Models, errors, concurrency utilities

**Files:**
- Create: `Packages/MTPKit/Sources/MTPKit/Models.swift`
- Create: `Packages/MTPKit/Sources/MTPKit/MTPError.swift`
- Create: `Packages/MTPKit/Sources/MTPKit/Concurrency.swift`
- Delete: `Packages/MTPKit/Tests/MTPKitTests/ScaffoldTests.swift`
- Test: `Packages/MTPKit/Tests/MTPKitTests/ModelsTests.swift`, `ConcurrencyTests.swift`, `TestSupport.swift`

**Interfaces:**
- Produces:
  - `typealias DeviceID = String`
  - `struct DeviceInfo { id: DeviceID; manufacturer: String; model: String; state: DeviceState; displayName: String }`
  - `enum DeviceState { ready, unavailable(MTPError) }`
  - `struct StorageInfo { id: UInt32; name: String; capacity: UInt64; freeSpace: UInt64 }`
  - `struct FileEntry { static rootID: UInt32 = 0xFFFF_FFFF; objectID, parentID, storageID: UInt32; name: String; size: UInt64; modified: Date?; isFolder: Bool }`
  - `struct FolderRef { deviceID: DeviceID; storageID: UInt32; folderID: UInt32 }`
  - `enum MTPError: Error, Codable, Hashable, LocalizedError` with the cases:
    - `deviceDisconnected`
    - `deviceLocked`
    - `deviceBusy`
    - `claimedByOtherProcess`
    - `storageFull(needed: UInt64, available: UInt64)`
    - `nameConflict(String)`
    - `notFound`
    - `timeout`
    - `cancelled`
    - `serviceInterrupted`
    - `underlying(code: Int, message: String)`

    It also provides `static func from(_ error: Error) -> MTPError` and `static let unexpectedResponse`.
  - `struct Unchecked<Value>: @unchecked Sendable { let value: Value }`
  - `final class OnceContinuation<T: Sendable>` with `resume(returning:)` and `resume(throwing:)`
  - `final class LockedFlag` with `set()` and `isSet`
  - `func withTimeout<T: Sendable>(_ duration: Duration, onTimeout: @escaping @Sendable () async -> Void, operation: @escaping @Sendable () async throws -> T) async throws -> T`

All model types are `Codable, Hashable, Sendable`, and every type except `FolderRef` is also `Identifiable`. Every type has a public memberwise `init` with the property order shown.

- [ ] **Step 1: Write the failing tests**

`Packages/MTPKit/Tests/MTPKitTests/TestSupport.swift`:

```swift
import Foundation
import Testing

func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MTPKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func contents(of directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
}

/// Polls until `condition` holds or the timeout passes (then records a failure).
func eventually(timeout: Duration = .seconds(3), _ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("condition not met within \(timeout)")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Thread-safe append-only log for ordering assertions.
final class Log<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []
    func append(_ element: Element) { lock.withLock { storage.append(element) } }
    var items: [Element] { lock.withLock { storage } }
}
```

`Packages/MTPKit/Tests/MTPKitTests/ModelsTests.swift`:

```swift
import Foundation
import Testing
@testable import MTPKit

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

@Test func fileEntryRoundTripsLargeSize() throws {
    let entry = FileEntry(objectID: 7, parentID: FileEntry.rootID, storageID: 0x10001,
                          name: "movie.mkv", size: 5_368_709_120,
                          modified: Date(timeIntervalSince1970: 1_700_000_000), isFolder: false)
    #expect(try roundTrip(entry) == entry)
    #expect(try roundTrip(entry).size == 5_368_709_120)
}

@Test func deviceInfoRoundTripsUnavailableState() throws {
    let info = DeviceInfo(id: "1-4", manufacturer: "Samsung", model: "Galaxy S25",
                          state: .unavailable(.storageFull(needed: 10, available: 2)))
    #expect(try roundTrip(info) == info)
}

@Test func displayNameFallsBackToManufacturer() {
    #expect(DeviceInfo(id: "a", manufacturer: "Google", model: "", state: .ready).displayName == "Google")
    #expect(DeviceInfo(id: "a", manufacturer: "Google", model: "Pixel 9", state: .ready).displayName == "Pixel 9")
}

@Test func folderRefDefaultsToRoot() {
    #expect(FolderRef(deviceID: "d", storageID: 1).folderID == FileEntry.rootID)
}

@Test func errorFromWrapsForeignErrors() {
    #expect(MTPError.from(MTPError.timeout) == .timeout)
    let wrapped = MTPError.from(CocoaError(.fileNoSuchFile))
    guard case .underlying(let code, _) = wrapped else { Issue.record("expected underlying"); return }
    #expect(code == CocoaError.fileNoSuchFile.rawValue)
}

@Test func everyErrorHasAMessage() {
    let all: [MTPError] = [.deviceDisconnected, .deviceLocked, .deviceBusy, .claimedByOtherProcess,
                           .storageFull(needed: 2_000_000_000, available: 1_000), .nameConflict("a.txt"),
                           .notFound, .timeout, .cancelled, .serviceInterrupted,
                           .underlying(code: 1, message: "boom")]
    for error in all { #expect(!(error.errorDescription ?? "").isEmpty) }
    #expect(MTPError.nameConflict("a.txt").errorDescription!.contains("a.txt"))
}
```

`Packages/MTPKit/Tests/MTPKitTests/ConcurrencyTests.swift`:

```swift
import Foundation
import Testing
@testable import MTPKit

@Test func onceContinuationIgnoresSecondResume() async throws {
    let value: Int = try await withCheckedThrowingContinuation { continuation in
        let once = OnceContinuation(continuation)
        once.resume(returning: 1)
        once.resume(returning: 2)
        once.resume(throwing: MTPError.timeout)
    }
    #expect(value == 1)
}

@Test func withTimeoutReturnsFastResult() async throws {
    let called = LockedFlag()
    let value = try await withTimeout(.seconds(5), onTimeout: { called.set() }) { 42 }
    #expect(value == 42)
    #expect(!called.isSet)
}

@Test func withTimeoutThrowsTimeoutAndRunsHandler() async {
    let called = LockedFlag()
    await #expect(throws: MTPError.timeout) {
        try await withTimeout(.milliseconds(50), onTimeout: { called.set() }) {
            try await Task.sleep(for: .seconds(10))
            return 1
        }
    }
    #expect(called.isSet)
}

@Test func withTimeoutPassesThroughOperationErrors() async {
    await #expect(throws: MTPError.notFound) {
        try await withTimeout(.seconds(5), onTimeout: {}) { () async throws -> Int in throw MTPError.notFound }
    }
}
```

Delete `Packages/MTPKit/Tests/MTPKitTests/ScaffoldTests.swift`. The service-name constant stays in `MTPKit.swift`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/MTPKit`
Expected: compile errors such as `cannot find 'FileEntry' in scope`.

- [ ] **Step 3: Implement `Models.swift`**

```swift
import Foundation

public typealias DeviceID = String

public enum DeviceState: Codable, Hashable, Sendable {
    case ready
    case unavailable(MTPError)
}

public struct DeviceInfo: Codable, Hashable, Sendable, Identifiable {
    public let id: DeviceID
    public var manufacturer: String
    public var model: String
    public var state: DeviceState

    public init(id: DeviceID, manufacturer: String, model: String, state: DeviceState) {
        self.id = id
        self.manufacturer = manufacturer
        self.model = model
        self.state = state
    }

    public var displayName: String { model.isEmpty ? manufacturer : model }
}

public struct StorageInfo: Codable, Hashable, Sendable, Identifiable {
    public let id: UInt32
    public var name: String
    public var capacity: UInt64
    public var freeSpace: UInt64

    public init(id: UInt32, name: String, capacity: UInt64, freeSpace: UInt64) {
        self.id = id
        self.name = name
        self.capacity = capacity
        self.freeSpace = freeSpace
    }
}

public struct FileEntry: Codable, Hashable, Sendable, Identifiable {
    /// MTP's "root of storage" folder ID, used when listing.
    public static let rootID: UInt32 = 0xFFFF_FFFF

    public let objectID: UInt32
    public var parentID: UInt32
    public var storageID: UInt32
    public var name: String
    public var size: UInt64
    public var modified: Date?
    public var isFolder: Bool

    public init(objectID: UInt32, parentID: UInt32, storageID: UInt32, name: String,
                size: UInt64, modified: Date?, isFolder: Bool) {
        self.objectID = objectID
        self.parentID = parentID
        self.storageID = storageID
        self.name = name
        self.size = size
        self.modified = modified
        self.isFolder = isFolder
    }

    public var id: UInt32 { objectID }
}

public struct FolderRef: Codable, Hashable, Sendable {
    public let deviceID: DeviceID
    public let storageID: UInt32
    public let folderID: UInt32

    public init(deviceID: DeviceID, storageID: UInt32, folderID: UInt32 = FileEntry.rootID) {
        self.deviceID = deviceID
        self.storageID = storageID
        self.folderID = folderID
    }
}
```

- [ ] **Step 4: Implement `MTPError.swift`**

```swift
import Foundation

public enum MTPError: Error, Codable, Hashable, Sendable {
    case deviceDisconnected
    case deviceLocked
    case deviceBusy
    case claimedByOtherProcess
    case storageFull(needed: UInt64, available: UInt64)
    case nameConflict(String)
    case notFound
    case timeout
    case cancelled
    case serviceInterrupted
    case underlying(code: Int, message: String)

    public static let unexpectedResponse = MTPError.underlying(code: -2, message: "Unexpected response from MTPHelper.")

    public static func from(_ error: Error) -> MTPError {
        if let error = error as? MTPError { return error }
        let ns = error as NSError
        return .underlying(code: ns.code, message: ns.localizedDescription)
    }
}

extension MTPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .deviceDisconnected:
            String(localized: "The phone was disconnected.")
        case .deviceLocked:
            String(localized: "Unlock your phone and choose “File transfer” in the USB notification.")
        case .deviceBusy:
            String(localized: "The phone is busy. Try again in a moment.")
        case .claimedByOtherProcess:
            String(localized: "Another app is using the phone. Quit Image Capture or Photos and try again.")
        case .storageFull(let needed, let available):
            String(localized: "Not enough space on the phone. Needs \(Self.bytes(needed)), but only \(Self.bytes(available)) is available.")
        case .nameConflict(let name):
            String(localized: "An item named “\(name)” already exists in this folder.")
        case .notFound:
            String(localized: "The item no longer exists on the phone.")
        case .timeout:
            String(localized: "The phone stopped responding.")
        case .cancelled:
            String(localized: "The transfer was cancelled.")
        case .serviceInterrupted:
            String(localized: "The connection to the phone was interrupted.")
        case .underlying(_, let message):
            message
        }
    }

    private static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }
}
```

- [ ] **Step 5: Implement `Concurrency.swift`**

```swift
import Foundation

/// Carries a non-Sendable value across isolation when the caller guarantees safe use
/// (AppKit callbacks, XPC proxies).
public struct Unchecked<Value>: @unchecked Sendable {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}

/// A continuation that several racing paths may try to resume; only the first wins.
public final class OnceContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    public init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    public func resume(with result: Result<T, Error>) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    public func resume(returning value: T) { resume(with: .success(value)) }
    public func resume(throwing error: Error) { resume(with: .failure(error)) }
}

public final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public func set() { lock.withLock { value = true } }
    public var isSet: Bool { lock.withLock { value } }
}

/// Runs `operation`; if it takes longer than `duration`, calls `onTimeout` and throws `.timeout`.
/// `onTimeout` must make a stuck `operation` finish (e.g. restart the service that is hung),
/// because the task group waits for every child before returning.
public func withTimeout<T: Sendable>(
    _ duration: Duration,
    onTimeout: @escaping @Sendable () async -> Void,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let timedOut = LockedFlag()
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            timedOut.set()
            await onTimeout()
            throw MTPError.timeout
        }
        defer { group.cancelAll() }
        do {
            guard let result = try await group.next() else { throw MTPError.timeout }
            return result
        } catch {
            throw timedOut.isSet ? MTPError.timeout : error
        }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --package-path Packages/MTPKit`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add -A Packages/MTPKit
git commit -m "feat(MTPKit): models, typed errors and concurrency helpers"
```

---

### Task 4: `MTPDevice` protocol, `FakeDevice`, `FakeDeviceProvider`

**Files:**
- Create: `Packages/MTPKit/Sources/MTPKit/MTPDevice.swift`
- Create: `Packages/MTPKit/Sources/MTPKit/FakeDevice.swift`
- Create: `Packages/MTPKit/Sources/MTPKit/FakeDeviceProvider.swift`
- Test: `Packages/MTPKit/Tests/MTPKitTests/FakeDeviceTests.swift`

**Interfaces:**
- Consumes: Task 3 models and errors.
- Produces:
  - `typealias ProgressHandler = (_ done: UInt64, _ total: UInt64) -> Bool`. Returning `false` cancels.
  - `protocol MTPDevice: AnyObject, Sendable` with:
    - `info: DeviceInfo`
    - `storages() throws -> [StorageInfo]`
    - `listFolder(storageID:folderID:) throws -> [FileEntry]`
    - `download(objectID:to:progress:) throws`
    - `upload(from:name:size:storageID:parentID:progress:) throws -> FileEntry`
    - `createFolder(name:storageID:parentID:) throws -> FileEntry`
    - `rename(objectID:to:) throws`
    - `delete(objectID:) throws`
    - `close()`
  - `struct AttachedDevice { id: DeviceID; manufacturer: String; model: String }`
  - `protocol DeviceProvider: Sendable` with `attachedDevices() -> [AttachedDevice]` and `open(_:) throws -> any MTPDevice`
  - `final class FakeDevice` with:
    - `init(id:manufacturer:model:storages:chunkSize:chunkDelay:)`
    - `addFolder(_:in:storageID:)` and `addFile(_:data:in:storageID:modified:)`, both `@discardableResult -> FileEntry`
    - `inject(_ fault: Fault)` and `releaseHang()`
    - `data(of:) -> Data?` and `children(of:storageID:) -> [FileEntry]`
    - `storage(_:) -> StorageInfo?` and `isClosed`

    `Fault` has three cases: `fail(MTPError)`, `disconnectAfter(bytes: UInt64)` and `hang`.
  - `final class FakeDeviceProvider: DeviceProvider` with:
    - `attach(_ device: FakeDevice)`, `attachUnavailable(_:error:)` and `detach(_:)`
    - `openCount(_:) -> Int`
    - `static func demo() -> FakeDeviceProvider`

**`FakeDevice` semantics:**
- Every operation consumes at most one injected fault.
  - `.fail(e)` throws `e`.
  - `.hang` blocks that operation until `releaseHang()`, without holding the lock.
  - `.disconnectAfter(n)` makes a transfer stop with `.deviceDisconnected` once `n` bytes have moved. A non-transfer op disconnects immediately. After a disconnect, every operation throws `.deviceDisconnected`.
- Uploads create the object first and fill it chunk by chunk. A cancelled or disconnected upload therefore leaves a partial object on the device, the way a real Android phone does.
- Deleting a folder deletes its subtree.

- [ ] **Step 1: Write the failing tests**

`Packages/MTPKit/Tests/MTPKitTests/FakeDeviceTests.swift`:

```swift
import Foundation
import Testing
@testable import MTPKit

@Test func listsChildrenOfRootAndFolders() throws {
    let device = FakeDevice()
    let dcim = device.addFolder("DCIM")
    device.addFile("a.jpg", data: Data(count: 10), in: dcim.objectID)
    device.addFile("notes.txt", data: Data("x".utf8))
    let root = try device.listFolder(storageID: 1, folderID: FileEntry.rootID)
    #expect(root.map(\.name) == ["DCIM", "notes.txt"])
    #expect(try device.listFolder(storageID: 1, folderID: dcim.objectID).map(\.name) == ["a.jpg"])
}

@Test func failFaultAppliesToNextOperationOnly() throws {
    let device = FakeDevice()
    device.inject(.fail(.deviceBusy))
    #expect(throws: MTPError.deviceBusy) { try device.storages() }
    #expect(try device.storages().count == 1)
}

@Test func disconnectIsPermanent() throws {
    let device = FakeDevice()
    device.inject(.disconnectAfter(bytes: 0))
    #expect(throws: MTPError.deviceDisconnected) { try device.storages() }
    #expect(throws: MTPError.deviceDisconnected) { try device.storages() }
}

@Test func cancelledUploadLeavesPartialObject() throws {
    let device = FakeDevice(chunkSize: 4)
    let dir = try makeTempDirectory()
    let file = dir.appendingPathComponent("big.bin")
    try Data(count: 40).write(to: file)
    #expect(throws: MTPError.cancelled) {
        try device.upload(from: file, name: "big.bin", size: 40, storageID: 1,
                          parentID: FileEntry.rootID) { done, _ in done < 8 }
    }
    let partial = try #require(device.children(of: FileEntry.rootID).first)
    #expect(partial.name == "big.bin")
    #expect(device.data(of: partial.objectID)!.count < 40)
}

@Test func deletingFolderRemovesSubtree() throws {
    let device = FakeDevice()
    let a = device.addFolder("A")
    let b = device.addFolder("B", in: a.objectID)
    device.addFile("x", data: Data(count: 1), in: b.objectID)
    try device.delete(objectID: a.objectID)
    #expect(device.children(of: FileEntry.rootID).isEmpty)
    #expect(device.children(of: b.objectID).isEmpty)
}

@Test func providerReportsAttachedAndOpens() throws {
    let provider = FakeDeviceProvider()
    provider.attach(FakeDevice(id: "p1"))
    provider.attachUnavailable(AttachedDevice(id: "p2", manufacturer: "Samsung", model: "S25"), error: .deviceLocked)
    #expect(provider.attachedDevices().map(\.id) == ["p1", "p2"])
    #expect(try provider.open(provider.attachedDevices()[0]).info.id == "p1")
    #expect(throws: MTPError.deviceLocked) { try provider.open(provider.attachedDevices()[1]) }
    #expect(provider.openCount("p1") == 1)
    provider.detach("p1")
    #expect(provider.attachedDevices().map(\.id) == ["p2"])
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/MTPKit --filter FakeDeviceTests`
Expected: compile error `cannot find 'FakeDevice' in scope`.

- [ ] **Step 3: Implement `MTPDevice.swift`**

```swift
import Foundation

/// Called during transfers with bytes done / total. Return `false` to cancel.
public typealias ProgressHandler = (_ done: UInt64, _ total: UInt64) -> Bool

/// One connected phone. Implementations are not thread-safe;
/// `DeviceWorker` guarantees that all calls happen on one thread.
public protocol MTPDevice: AnyObject, Sendable {
    var info: DeviceInfo { get }
    func storages() throws -> [StorageInfo]
    func listFolder(storageID: UInt32, folderID: UInt32) throws -> [FileEntry]
    func download(objectID: UInt32, to fileURL: URL, progress: ProgressHandler) throws
    func upload(from fileURL: URL, name: String, size: UInt64, storageID: UInt32, parentID: UInt32,
                progress: ProgressHandler) throws -> FileEntry
    func createFolder(name: String, storageID: UInt32, parentID: UInt32) throws -> FileEntry
    func rename(objectID: UInt32, to newName: String) throws
    func delete(objectID: UInt32) throws
    func close()
}

public struct AttachedDevice: Hashable, Sendable {
    public let id: DeviceID
    public let manufacturer: String
    public let model: String

    public init(id: DeviceID, manufacturer: String, model: String) {
        self.id = id
        self.manufacturer = manufacturer
        self.model = model
    }
}

/// Finds and opens phones. `attachedDevices()` must be cheap; `open` may block for seconds.
public protocol DeviceProvider: Sendable {
    func attachedDevices() -> [AttachedDevice]
    func open(_ device: AttachedDevice) throws -> any MTPDevice
}
```

- [ ] **Step 4: Implement `FakeDevice.swift`**

```swift
import Foundation

/// In-memory phone for tests, previews and `-UseFakeDevices`.
public final class FakeDevice: MTPDevice, @unchecked Sendable {
    public enum Fault: Sendable, Equatable {
        case fail(MTPError)
        case disconnectAfter(bytes: UInt64)
        case hang
    }

    private struct Node {
        var entry: FileEntry
        var data: Data
    }

    public let info: DeviceInfo
    private let chunkSize: Int
    private let chunkDelay: TimeInterval
    private let lock = NSLock()
    private let hangGate = DispatchSemaphore(value: 0)
    private var storageList: [StorageInfo]
    private var nodes: [UInt32: Node] = [:]
    private var nextID: UInt32 = 1
    private var faults: [Fault] = []
    private var disconnected = false
    private var closed = false

    public init(id: DeviceID = "fake-1", manufacturer: String = "Google", model: String = "Pixel 9",
                storages: [StorageInfo] = [StorageInfo(id: 1, name: "Internal shared storage",
                                                       capacity: 128_000_000_000, freeSpace: 64_000_000_000)],
                chunkSize: Int = 4096, chunkDelay: TimeInterval = 0) {
        self.info = DeviceInfo(id: id, manufacturer: manufacturer, model: model, state: .ready)
        self.storageList = storages
        self.chunkSize = chunkSize
        self.chunkDelay = chunkDelay
    }

    // MARK: Test setup and inspection

    @discardableResult
    public func addFolder(_ name: String, in parentID: UInt32 = FileEntry.rootID, storageID: UInt32 = 1) -> FileEntry {
        lock.withLock { insert(name: name, data: Data(), parentID: parentID, storageID: storageID, isFolder: true, modified: nil) }
    }

    @discardableResult
    public func addFile(_ name: String, data: Data, in parentID: UInt32 = FileEntry.rootID, storageID: UInt32 = 1,
                        modified: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> FileEntry {
        lock.withLock { insert(name: name, data: data, parentID: parentID, storageID: storageID, isFolder: false, modified: modified) }
    }

    public func inject(_ fault: Fault) { lock.withLock { faults.append(fault) } }
    public func releaseHang() { hangGate.signal() }
    public func data(of objectID: UInt32) -> Data? { lock.withLock { nodes[objectID]?.data } }
    public func storage(_ id: UInt32) -> StorageInfo? { lock.withLock { storageList.first { $0.id == id } } }
    public var isClosed: Bool { lock.withLock { closed } }

    public func children(of parentID: UInt32, storageID: UInt32 = 1) -> [FileEntry] {
        lock.withLock {
            nodes.values.map(\.entry)
                .filter { $0.parentID == parentID && $0.storageID == storageID }
                .sorted { $0.objectID < $1.objectID }
        }
    }

    // MARK: MTPDevice

    public func storages() throws -> [StorageInfo] {
        try beginSimple()
        return lock.withLock { storageList }
    }

    public func listFolder(storageID: UInt32, folderID: UInt32) throws -> [FileEntry] {
        try beginSimple()
        try lock.withLock { try requireFolder(folderID) }
        return children(of: folderID, storageID: storageID)
    }

    public func download(objectID: UInt32, to fileURL: URL, progress: ProgressHandler) throws {
        let limit = try beginTransfer()
        guard let data = lock.withLock({ nodes[objectID]?.data }) else { throw MTPError.notFound }
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw MTPError.underlying(code: -1, message: "Cannot create \(fileURL.path)")
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        let total = UInt64(data.count)
        var done: UInt64 = 0
        while done < total {
            if let limit, done >= limit { markDisconnected(); throw MTPError.deviceDisconnected }
            let end = min(done + UInt64(chunkSize), total)
            try handle.write(contentsOf: data[Int(done)..<Int(end)])
            done = end
            if chunkDelay > 0 { Thread.sleep(forTimeInterval: chunkDelay) }
            if !progress(done, total) { throw MTPError.cancelled }
        }
    }

    public func upload(from fileURL: URL, name: String, size: UInt64, storageID: UInt32, parentID: UInt32,
                       progress: ProgressHandler) throws -> FileEntry {
        let limit = try beginTransfer()
        let entry: FileEntry = try lock.withLock {
            try requireFolder(parentID)
            guard let index = storageList.firstIndex(where: { $0.id == storageID }) else { throw MTPError.notFound }
            if storageList[index].freeSpace < size {
                throw MTPError.storageFull(needed: size, available: storageList[index].freeSpace)
            }
            return insert(name: name, data: Data(), parentID: parentID, storageID: storageID, isFolder: false, modified: Date())
        }
        let source = try Data(contentsOf: fileURL)
        let total = UInt64(source.count)
        var done: UInt64 = 0
        while done < total {
            if let limit, done >= limit { markDisconnected(); throw MTPError.deviceDisconnected }
            let end = min(done + UInt64(chunkSize), total)
            let chunk = source[Int(done)..<Int(end)]
            lock.withLock { nodes[entry.objectID]?.data.append(chunk) }
            done = end
            if chunkDelay > 0 { Thread.sleep(forTimeInterval: chunkDelay) }
            if !progress(done, total) { throw MTPError.cancelled }
        }
        return lock.withLock {
            nodes[entry.objectID]?.entry.size = total
            if let index = storageList.firstIndex(where: { $0.id == storageID }) {
                storageList[index].freeSpace -= min(total, storageList[index].freeSpace)
            }
            return nodes[entry.objectID]!.entry
        }
    }

    public func createFolder(name: String, storageID: UInt32, parentID: UInt32) throws -> FileEntry {
        try beginSimple()
        return try lock.withLock {
            try requireFolder(parentID)
            return insert(name: name, data: Data(), parentID: parentID, storageID: storageID, isFolder: true, modified: Date())
        }
    }

    public func rename(objectID: UInt32, to newName: String) throws {
        try beginSimple()
        try lock.withLock {
            guard nodes[objectID] != nil else { throw MTPError.notFound }
            nodes[objectID]!.entry.name = newName
        }
    }

    public func delete(objectID: UInt32) throws {
        try beginSimple()
        try lock.withLock {
            guard nodes[objectID] != nil else { throw MTPError.notFound }
            removeSubtree(objectID)
        }
    }

    public func close() { lock.withLock { closed = true } }

    // MARK: Internals (call with lock held unless noted)

    private func insert(name: String, data: Data, parentID: UInt32, storageID: UInt32, isFolder: Bool, modified: Date?) -> FileEntry {
        let entry = FileEntry(objectID: nextID, parentID: parentID, storageID: storageID, name: name,
                              size: UInt64(data.count), modified: modified, isFolder: isFolder)
        nodes[nextID] = Node(entry: entry, data: data)
        nextID += 1
        return entry
    }

    private func requireFolder(_ id: UInt32) throws {
        if id == FileEntry.rootID { return }
        guard let node = nodes[id], node.entry.isFolder else { throw MTPError.notFound }
    }

    private func removeSubtree(_ id: UInt32) {
        for child in nodes.values where child.entry.parentID == id { removeSubtree(child.entry.objectID) }
        nodes[id] = nil
    }

    private func markDisconnected() { lock.withLock { disconnected = true } }

    /// Lock NOT held. Consumes one fault; returns a byte limit for `.disconnectAfter`.
    private func beginTransfer() throws -> UInt64? {
        let fault: Fault? = try lock.withLock {
            if disconnected { throw MTPError.deviceDisconnected }
            return faults.isEmpty ? nil : faults.removeFirst()
        }
        switch fault {
        case .fail(let error): throw error
        case .hang: hangGate.wait(); return nil
        case .disconnectAfter(let bytes): return bytes
        case nil: return nil
        }
    }

    /// Lock NOT held. Non-transfer operations treat `.disconnectAfter` as an immediate disconnect.
    private func beginSimple() throws {
        if try beginTransfer() != nil {
            markDisconnected()
            throw MTPError.deviceDisconnected
        }
    }
}
```

- [ ] **Step 5: Implement `FakeDeviceProvider.swift`**

```swift
import Foundation

public final class FakeDeviceProvider: DeviceProvider, @unchecked Sendable {
    private enum Slot {
        case device(FakeDevice)
        case unavailable(AttachedDevice, MTPError)

        var attached: AttachedDevice {
            switch self {
            case .device(let d): AttachedDevice(id: d.info.id, manufacturer: d.info.manufacturer, model: d.info.model)
            case .unavailable(let a, _): a
            }
        }
    }

    private let lock = NSLock()
    private var slots: [DeviceID: Slot] = [:]
    private var opens: [DeviceID: Int] = [:]

    public init() {}

    /// Attaches (or replaces) a working device.
    public func attach(_ device: FakeDevice) { lock.withLock { slots[device.info.id] = .device(device) } }

    /// Attaches a device whose `open` fails with `error` (e.g. a locked phone).
    public func attachUnavailable(_ device: AttachedDevice, error: MTPError) {
        lock.withLock { slots[device.id] = .unavailable(device, error) }
    }

    public func detach(_ id: DeviceID) { lock.withLock { slots[id] = nil } }
    public func openCount(_ id: DeviceID) -> Int { lock.withLock { opens[id, default: 0] } }

    public func attachedDevices() -> [AttachedDevice] {
        lock.withLock { slots.values.map(\.attached).sorted { $0.id < $1.id } }
    }

    public func open(_ device: AttachedDevice) throws -> any MTPDevice {
        try lock.withLock {
            opens[device.id, default: 0] += 1
            switch slots[device.id] {
            case .device(let d): return d
            case .unavailable(_, let error): throw error
            case nil: throw MTPError.deviceDisconnected
            }
        }
    }

    /// Two demo phones: a working Pixel with sample folders and a locked Galaxy.
    public static func demo() -> FakeDeviceProvider {
        let provider = FakeDeviceProvider()
        let pixel = FakeDevice(id: "demo-pixel", manufacturer: "Google", model: "Pixel 9",
                               chunkSize: 256 * 1024, chunkDelay: 0.05)
        let dcim = pixel.addFolder("DCIM")
        let camera = pixel.addFolder("Camera", in: dcim.objectID)
        for i in 1...12 {
            pixel.addFile(String(format: "IMG_%04d.jpg", i), data: Data(count: 2_000_000), in: camera.objectID)
        }
        pixel.addFolder("Download")
        pixel.addFolder("Music")
        pixel.addFile("notes.txt", data: Data("Hello from Tether".utf8))
        provider.attach(pixel)
        provider.attachUnavailable(AttachedDevice(id: "demo-galaxy", manufacturer: "Samsung", model: "Galaxy S25"),
                                   error: .deviceLocked)
        return provider
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --package-path Packages/MTPKit`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add -A Packages/MTPKit
git commit -m "feat(MTPKit): MTPDevice protocol and fault-injecting FakeDevice"
```

---

### Task 5: `DeviceWorker`: one thread per device with priorities

**Files:**
- Create: `Packages/MTPKit/Sources/MTPKit/DeviceWorker.swift`
- Test: `Packages/MTPKit/Tests/MTPKitTests/DeviceWorkerTests.swift`

**Interfaces:**
- Consumes: `MTPDevice`, `MTPError`, `OnceContinuation` (Tasks 3–4)
- Produces:
  - `final class DeviceWorker: Sendable-safe`
  - `enum Priority { interactive, transfer, background }`
  - `init(device: any MTPDevice, name: String)`
  - `func perform<T: Sendable>(_ priority: Priority, _ body: @escaping @Sendable (any MTPDevice) throws -> T) async throws -> T`. Errors are normalized with `MTPError.from`.
  - `func shutdown(reason: MTPError)`. It fails the running job and all queued jobs with `reason`, rejects new work with `reason`, and closes the device once the running job returns.

The rules: a higher priority always runs first, jobs of the same priority run in FIFO order, and a running job is never preempted.

- [ ] **Step 1: Write the failing tests**

`Packages/MTPKit/Tests/MTPKitTests/DeviceWorkerTests.swift`:

```swift
import Foundation
import Testing
@testable import MTPKit

@Test func performReturnsResultFromWorkerThread() async throws {
    let worker = DeviceWorker(device: FakeDevice(), name: "t")
    let count = try await worker.perform(.interactive) { try $0.storages().count }
    #expect(count == 1)
    let name = try await worker.perform(.interactive) { _ in Thread.current.name ?? "" }
    #expect(name.contains("DeviceWorker"))
}

@Test func performMapsErrors() async {
    let worker = DeviceWorker(device: FakeDevice(), name: "t")
    await #expect(throws: MTPError.self) {
        try await worker.perform(.interactive) { _ -> Int in throw CocoaError(.fileNoSuchFile) }
    }
}

@Test func interactiveJobsRunBeforeQueuedTransfers() async throws {
    let worker = DeviceWorker(device: FakeDevice(), name: "t")
    let gate = DispatchSemaphore(value: 0)
    let order = Log<String>()
    let blocker = Task { try await worker.perform(.transfer) { _ in gate.wait(); order.append("blocker") } }
    try await Task.sleep(for: .milliseconds(50))
    let background = Task { try await worker.perform(.background) { _ in order.append("background") } }
    try await Task.sleep(for: .milliseconds(20))
    let transfer = Task { try await worker.perform(.transfer) { _ in order.append("transfer") } }
    try await Task.sleep(for: .milliseconds(20))
    let interactive = Task { try await worker.perform(.interactive) { _ in order.append("interactive") } }
    try await Task.sleep(for: .milliseconds(20))
    gate.signal()
    _ = try await (blocker.value, background.value, transfer.value, interactive.value)
    #expect(order.items == ["blocker", "interactive", "transfer", "background"])
}

@Test func shutdownFailsRunningAndQueuedJobs() async throws {
    let device = FakeDevice()
    let worker = DeviceWorker(device: device, name: "t")
    let gate = DispatchSemaphore(value: 0)
    let running = Task { try await worker.perform(.transfer) { _ in _ = gate.wait() } }
    try await Task.sleep(for: .milliseconds(50))
    let queued = Task { try await worker.perform(.interactive) { _ in 1 } }
    try await Task.sleep(for: .milliseconds(20))
    worker.shutdown(reason: .deviceDisconnected)
    await #expect(throws: MTPError.deviceDisconnected) { try await running.value }
    await #expect(throws: MTPError.deviceDisconnected) { try await queued.value }
    await #expect(throws: MTPError.deviceDisconnected) { try await worker.perform(.interactive) { _ in 1 } }
    gate.signal()
    try await eventually { device.isClosed }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/MTPKit --filter DeviceWorkerTests`
Expected: compile error `cannot find 'DeviceWorker' in scope`.

- [ ] **Step 3: Implement `DeviceWorker.swift`**

```swift
import Foundation

/// Owns one device and runs every operation on a dedicated thread, highest priority first.
/// libmtp calls block, and a phone serves one request at a time, so a running job is never preempted.
public final class DeviceWorker: @unchecked Sendable {
    public enum Priority: Int, Sendable, CaseIterable {
        case interactive = 0, transfer = 1, background = 2
    }

    private struct Job {
        let run: (any MTPDevice) -> Void
        let fail: (MTPError) -> Void
    }

    private let device: any MTPDevice
    private let condition = NSCondition()
    private var queues: [[Job]] = Array(repeating: [], count: Priority.allCases.count)
    private var current: Job?
    private var stopReason: MTPError?

    public init(device: any MTPDevice, name: String) {
        self.device = device
        let thread = Thread { [self] in runLoop() }
        thread.name = "DeviceWorker \(name)"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    public func perform<T: Sendable>(_ priority: Priority,
                                     _ body: @escaping @Sendable (any MTPDevice) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = OnceContinuation(continuation)
            let job = Job(
                run: { device in
                    do { once.resume(returning: try body(device)) } catch { once.resume(throwing: MTPError.from(error)) }
                },
                fail: { once.resume(throwing: $0) }
            )
            condition.lock()
            if let stopReason {
                condition.unlock()
                job.fail(stopReason)
                return
            }
            queues[priority.rawValue].append(job)
            condition.signal()
            condition.unlock()
        }
    }

    public func shutdown(reason: MTPError) {
        condition.lock()
        guard stopReason == nil else { condition.unlock(); return }
        stopReason = reason
        let abandoned = (current.map { [$0] } ?? []) + queues.flatMap { $0 }
        queues = Array(repeating: [], count: Priority.allCases.count)
        condition.signal()
        condition.unlock()
        abandoned.forEach { $0.fail(reason) }
    }

    private func runLoop() {
        while true {
            condition.lock()
            while stopReason == nil && queues.allSatisfy(\.isEmpty) { condition.wait() }
            if stopReason != nil {
                current = nil
                condition.unlock()
                break
            }
            let index = queues.firstIndex { !$0.isEmpty }!
            let job = queues[index].removeFirst()
            current = job
            condition.unlock()

            job.run(device)

            condition.lock()
            current = nil
            condition.unlock()
        }
        device.close()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/MTPKit --filter DeviceWorkerTests`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add -A Packages/MTPKit
git commit -m "feat(MTPKit): DeviceWorker with priority queue and shutdown"
```

---

### Task 6: Downloads: partial files, unique and safe names, folders

**Files:**
- Create: `Packages/MTPKit/Sources/MTPKit/Transfers+Download.swift`
- Test: `Packages/MTPKit/Tests/MTPKitTests/DownloadTests.swift`

**Interfaces:**
- Consumes: `MTPDevice`, `FileEntry`, `ProgressHandler` (Task 4)
- Produces:
  - `enum Transfers` (namespace)
  - `static func download(_ entry: FileEntry, from: any MTPDevice, into directory: URL, progress: ProgressHandler) throws -> URL`
  - `static func safeName(_ name: String) -> String`
  - `static func uniqueName(for name: String, isTaken: (String) -> Bool) -> String`
  - `static func uniqueURL(for name: String, in directory: URL) -> URL`

**Rules:**
- Data is written to `<final>.partial` (a file, or a directory for folder downloads) and renamed on success.
- On any error the partial is removed and the error is rethrown as `MTPError`.
- The final name is `safeName(entry.name)`, made unique against both existing items and in-progress `.partial` items. The pattern is "a.txt" → "a 2.txt", "a 3.txt", and so on.
- Folder progress is cumulative across all files in the folder.

- [ ] **Step 1: Write the failing tests**

`Packages/MTPKit/Tests/MTPKitTests/DownloadTests.swift`:

```swift
import Foundation
import Testing
@testable import MTPKit

@Suite struct DownloadTests {
    let device = FakeDevice(chunkSize: 4096)

    @Test func downloadsFileAtomically() throws {
        let file = device.addFile("a.txt", data: Data("hello".utf8))
        let dir = try makeTempDirectory()
        let url = try Transfers.download(file, from: device, into: dir) { _, _ in true }
        #expect(url.lastPathComponent == "a.txt")
        #expect(try Data(contentsOf: url) == Data("hello".utf8))
        #expect(try contents(of: dir) == ["a.txt"])
    }

    @Test func keepsExistingFiles() throws {
        let file = device.addFile("a.txt", data: Data("new".utf8))
        let dir = try makeTempDirectory()
        try Data("old".utf8).write(to: dir.appendingPathComponent("a.txt"))
        let url = try Transfers.download(file, from: device, into: dir) { _, _ in true }
        #expect(url.lastPathComponent == "a 2.txt")
        #expect(try Data(contentsOf: dir.appendingPathComponent("a.txt")) == Data("old".utf8))
    }

    @Test func avoidsNamesOfInProgressDownloads() throws {
        let dir = try makeTempDirectory()
        try Data().write(to: dir.appendingPathComponent("a.txt.partial"))
        #expect(Transfers.uniqueURL(for: "a.txt", in: dir).lastPathComponent == "a 2.txt")
    }

    @Test func uniqueNameHandlesExtensionsAndFolders() {
        let taken: Set<String> = ["a.txt", "a 2.txt", "Photos", ".bashrc"]
        #expect(Transfers.uniqueName(for: "a.txt") { taken.contains($0) } == "a 3.txt")
        #expect(Transfers.uniqueName(for: "Photos") { taken.contains($0) } == "Photos 2")
        #expect(Transfers.uniqueName(for: ".bashrc") { taken.contains($0) } == ".bashrc 2")
        #expect(Transfers.uniqueName(for: "free.txt") { taken.contains($0) } == "free.txt")
    }

    @Test func cancelRemovesPartial() throws {
        let file = device.addFile("big.bin", data: Data(count: 40_960))
        let dir = try makeTempDirectory()
        #expect(throws: MTPError.cancelled) {
            try Transfers.download(file, from: device, into: dir) { done, _ in done < 8192 }
        }
        #expect(try contents(of: dir).isEmpty)
    }

    @Test func disconnectRemovesPartial() throws {
        let file = device.addFile("big.bin", data: Data(count: 40_960))
        device.inject(.disconnectAfter(bytes: 8192))
        let dir = try makeTempDirectory()
        #expect(throws: MTPError.deviceDisconnected) {
            try Transfers.download(file, from: device, into: dir) { _, _ in true }
        }
        #expect(try contents(of: dir).isEmpty)
    }

    @Test func downloadsFolderTreeWithCumulativeProgress() throws {
        let dcim = device.addFolder("DCIM")
        let camera = device.addFolder("Camera", in: dcim.objectID)
        device.addFile("x.jpg", data: Data(count: 5000), in: camera.objectID)
        device.addFile("y.txt", data: Data(count: 3000), in: dcim.objectID)
        let dir = try makeTempDirectory()
        let last = Log<(UInt64, UInt64)>()
        let url = try Transfers.download(dcim, from: device, into: dir) { done, total in last.append((done, total)); return true }
        #expect(url.lastPathComponent == "DCIM")
        #expect(try Data(contentsOf: url.appendingPathComponent("Camera/x.jpg")).count == 5000)
        #expect(try Data(contentsOf: url.appendingPathComponent("y.txt")).count == 3000)
        #expect(last.items.last! == (8000, 8000))
        #expect(try contents(of: dir) == ["DCIM"])
    }

    @Test func sanitizesUnsafeNames() throws {
        let dir = try makeTempDirectory()
        let evil = device.addFile("../evil.txt", data: Data("e".utf8))
        let slashed = device.addFile("a/b.txt", data: Data("s".utf8))
        let dots = device.addFolder("..")
        device.addFile("inner.txt", data: Data("i".utf8), in: dots.objectID)
        for entry in [evil, slashed, dots] {
            _ = try Transfers.download(entry, from: device, into: dir) { _, _ in true }
        }
        #expect(try contents(of: dir) == ["..-evil.txt", "_", "a-b.txt"])
        #expect(try contents(of: dir.appendingPathComponent("_")) == ["inner.txt"])
        #expect(Transfers.safeName("") == "_")
        #expect(Transfers.safeName(".") == "_")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/MTPKit --filter DownloadTests`
Expected: compile error `cannot find 'Transfers' in scope`.

- [ ] **Step 3: Implement `Transfers+Download.swift`**

```swift
import Foundation

/// Device-agnostic transfer algorithms. Run them on a DeviceWorker thread.
public enum Transfers {}

extension Transfers {
    /// Downloads a file or folder into `directory` and returns the final URL.
    /// Writes to `<name>.partial` first, so failures never leave a broken item behind.
    public static func download(_ entry: FileEntry, from device: any MTPDevice, into directory: URL,
                                progress: ProgressHandler) throws -> URL {
        let fm = FileManager.default
        let final = uniqueURL(for: entry.name, in: directory)
        let partial = directory.appendingPathComponent(final.lastPathComponent + ".partial")
        try? fm.removeItem(at: partial)
        do {
            if entry.isFolder {
                try downloadFolder(entry, from: device, to: partial, progress: progress)
            } else {
                try device.download(objectID: entry.objectID, to: partial, progress: progress)
            }
            try fm.moveItem(at: partial, to: final)
            return final
        } catch {
            try? fm.removeItem(at: partial)
            throw MTPError.from(error)
        }
    }

    /// Makes a phone-supplied name safe as a single macOS path component.
    public static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\0", with: "")
        return (cleaned.isEmpty || cleaned == "." || cleaned == "..") ? "_" : cleaned
    }

    /// "a.txt" → "a 2.txt" → "a 3.txt" … until `isTaken` returns false.
    public static func uniqueName(for name: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ext.isEmpty ? name : ns.deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !isTaken(candidate) { return candidate }
            n += 1
        }
    }

    /// A URL in `directory` that collides with neither existing items nor in-progress `.partial` items.
    public static func uniqueURL(for name: String, in directory: URL) -> URL {
        let fm = FileManager.default
        let unique = uniqueName(for: safeName(name)) { candidate in
            fm.fileExists(atPath: directory.appendingPathComponent(candidate).path)
                || fm.fileExists(atPath: directory.appendingPathComponent(candidate + ".partial").path)
        }
        return directory.appendingPathComponent(unique)
    }

    private struct RemoteItem {
        let components: [String]
        let entry: FileEntry
    }

    private static func downloadFolder(_ folder: FileEntry, from device: any MTPDevice, to root: URL,
                                       progress: ProgressHandler) throws {
        var items: [RemoteItem] = []
        func walk(_ folderID: UInt32, _ prefix: [String]) throws {
            for child in try device.listFolder(storageID: folder.storageID, folderID: folderID) {
                let components = prefix + [safeName(child.name)]
                items.append(RemoteItem(components: components, entry: child))
                if child.isFolder { try walk(child.objectID, components) }
            }
        }
        try walk(folder.objectID, [])

        let fm = FileManager.default
        let total = items.reduce(UInt64(0)) { $0 + ($1.entry.isFolder ? 0 : $1.entry.size) }
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        var received: UInt64 = 0
        for item in items {
            let destination = item.components.reduce(root) { $0.appendingPathComponent($1) }
            if item.entry.isFolder {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            } else {
                let base = received
                try device.download(objectID: item.entry.objectID, to: destination) { done, _ in
                    progress(base + done, total)
                }
                received += item.entry.size
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/MTPKit --filter DownloadTests`
Expected: 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add -A Packages/MTPKit
git commit -m "feat(MTPKit): atomic file and folder downloads with safe unique names"
```

---

### Task 7: Uploads: free space, conflicts, folder trees, cleanup

**Files:**
- Create: `Packages/MTPKit/Sources/MTPKit/Transfers+Upload.swift`
- Test: `Packages/MTPKit/Tests/MTPKitTests/UploadTests.swift`

**Interfaces:**
- Consumes: `Transfers`, `MTPDevice` (Tasks 4, 6)
- Produces:
  - `static func upload(_ source: URL, to device: any MTPDevice, storageID: UInt32, parentID: UInt32, progress: ProgressHandler) throws -> FileEntry`. It returns the entry created for `source` itself.

**Rules:**
- **Before any bytes are sent:**
  - Scan the local tree, skipping hidden files.
  - Throw `.storageFull(needed:available:)` if the total size is more than the target storage's free space.
  - Throw `.nameConflict(name)` if the parent already has an item named `source.lastPathComponent`.
- **On failure after the transfer has started:**
  - Delete the partially created top-level object if the phone is still reachable.
  - For a single file, the object is found by name, excluding objects that already existed before the upload.
  - Cleanup errors are ignored.
- Progress is cumulative over all files.

- [ ] **Step 1: Write the failing tests**

`Packages/MTPKit/Tests/MTPKitTests/UploadTests.swift`:

```swift
import Foundation
import Testing
@testable import MTPKit

@Suite struct UploadTests {
    let root = FileEntry.rootID

    private func makeFile(_ name: String, bytes: Int, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
        return url
    }

    @Test func uploadsFileWithProgress() throws {
        let device = FakeDevice(chunkSize: 1000)
        let file = try makeFile("photo.jpg", bytes: 10_000, in: try makeTempDirectory())
        let last = Log<(UInt64, UInt64)>()
        let entry = try Transfers.upload(file, to: device, storageID: 1, parentID: root) { d, t in last.append((d, t)); return true }
        #expect(entry.name == "photo.jpg")
        #expect(device.data(of: entry.objectID) == (try Data(contentsOf: file)))
        #expect(last.items.last! == (10_000, 10_000))
    }

    @Test func uploadsFolderTreeSkippingHiddenFiles() throws {
        let device = FakeDevice()
        let dir = try makeTempDirectory()
        _ = try makeFile("Album/a.jpg", bytes: 100, in: dir)
        _ = try makeFile("Album/sub/b.jpg", bytes: 200, in: dir)
        _ = try makeFile("Album/.DS_Store", bytes: 10, in: dir)
        let album = try Transfers.upload(dir.appendingPathComponent("Album"), to: device, storageID: 1, parentID: root) { _, _ in true }
        #expect(album.isFolder)
        let children = device.children(of: album.objectID)
        #expect(children.map(\.name).sorted() == ["a.jpg", "sub"])
        let sub = try #require(children.first { $0.name == "sub" })
        #expect(device.children(of: sub.objectID).map(\.name) == ["b.jpg"])
    }

    @Test func rejectsWhenStorageFull() throws {
        let device = FakeDevice(storages: [StorageInfo(id: 1, name: "S", capacity: 10_000, freeSpace: 1000)])
        let file = try makeFile("a.bin", bytes: 2000, in: try makeTempDirectory())
        #expect(throws: MTPError.storageFull(needed: 2000, available: 1000)) {
            try Transfers.upload(file, to: device, storageID: 1, parentID: root) { _, _ in true }
        }
        #expect(device.children(of: root).isEmpty)
    }

    @Test func rejectsFiveGigabyteFileWhenFourAreFree() throws {
        let device = FakeDevice(storages: [StorageInfo(id: 1, name: "S", capacity: 8_000_000_000, freeSpace: 4_000_000_000)])
        let url = try makeTempDirectory().appendingPathComponent("movie.mkv")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 5_368_709_120) // sparse: instant, no disk use
        try handle.close()
        #expect(throws: MTPError.storageFull(needed: 5_368_709_120, available: 4_000_000_000)) {
            try Transfers.upload(url, to: device, storageID: 1, parentID: root) { _, _ in true }
        }
    }

    @Test func rejectsNameConflict() throws {
        let device = FakeDevice()
        device.addFile("photo.jpg", data: Data(count: 1))
        let file = try makeFile("photo.jpg", bytes: 10, in: try makeTempDirectory())
        #expect(throws: MTPError.nameConflict("photo.jpg")) {
            try Transfers.upload(file, to: device, storageID: 1, parentID: root) { _, _ in true }
        }
        #expect(device.children(of: root).count == 1)
    }

    @Test func cancelDeletesPartialObject() throws {
        let device = FakeDevice(chunkSize: 4096)
        let file = try makeFile("big.bin", bytes: 40_960, in: try makeTempDirectory())
        #expect(throws: MTPError.cancelled) {
            try Transfers.upload(file, to: device, storageID: 1, parentID: root) { done, _ in done < 8192 }
        }
        #expect(device.children(of: root).isEmpty)
    }

    @Test func cancelDuringFolderUploadDeletesFolder() throws {
        let device = FakeDevice(chunkSize: 100)
        let dir = try makeTempDirectory()
        _ = try makeFile("Album/a.jpg", bytes: 1000, in: dir)
        _ = try makeFile("Album/b.jpg", bytes: 1000, in: dir)
        #expect(throws: MTPError.cancelled) {
            try Transfers.upload(dir.appendingPathComponent("Album"), to: device, storageID: 1, parentID: root) { done, _ in done < 1500 }
        }
        #expect(device.children(of: root).isEmpty)
    }

    @Test func freeSpaceIsCheckedForWholeTree() throws {
        let device = FakeDevice(storages: [StorageInfo(id: 1, name: "S", capacity: 10_000, freeSpace: 250)])
        let dir = try makeTempDirectory()
        _ = try makeFile("Album/a.jpg", bytes: 200, in: dir)
        _ = try makeFile("Album/b.jpg", bytes: 200, in: dir)
        #expect(throws: MTPError.storageFull(needed: 400, available: 250)) {
            try Transfers.upload(dir.appendingPathComponent("Album"), to: device, storageID: 1, parentID: root) { _, _ in true }
        }
        #expect(device.children(of: root).isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/MTPKit --filter UploadTests`
Expected: compile error `type 'Transfers' has no member 'upload'`.

- [ ] **Step 3: Implement `Transfers+Upload.swift`**

```swift
import Foundation

extension Transfers {
    /// Uploads a file or folder into `parentID`. Checks space and name conflicts before sending anything.
    public static func upload(_ source: URL, to device: any MTPDevice, storageID: UInt32, parentID: UInt32,
                              progress: ProgressHandler) throws -> FileEntry {
        let items = try LocalItem.scan(source)
        let total = items.reduce(UInt64(0)) { $0 + $1.size }

        guard let storage = try device.storages().first(where: { $0.id == storageID }) else { throw MTPError.notFound }
        guard storage.freeSpace >= total else {
            throw MTPError.storageFull(needed: total, available: storage.freeSpace)
        }
        let name = source.lastPathComponent
        let existing = try device.listFolder(storageID: storageID, folderID: parentID)
        guard !existing.contains(where: { $0.name == name }) else { throw MTPError.nameConflict(name) }

        var createdRoot: FileEntry?
        var folderIDs: [[String]: UInt32] = [[]: parentID]
        var sent: UInt64 = 0
        do {
            for item in items {
                let parent = folderIDs[Array(item.components.dropLast())]!
                let itemName = item.components.last!
                let created: FileEntry
                if item.isDirectory {
                    created = try device.createFolder(name: itemName, storageID: storageID, parentID: parent)
                    folderIDs[item.components] = created.objectID
                } else {
                    let base = sent
                    created = try device.upload(from: item.url, name: itemName, size: item.size,
                                                storageID: storageID, parentID: parent) { done, _ in
                        progress(base + done, total)
                    }
                    sent += item.size
                }
                if createdRoot == nil { createdRoot = created }
            }
        } catch {
            if let createdRoot {
                try? device.delete(objectID: createdRoot.objectID)
            } else {
                removeIncomplete(named: name, in: parentID, storageID: storageID,
                                 keeping: Set(existing.map(\.objectID)), on: device)
            }
            throw MTPError.from(error)
        }
        return createdRoot!
    }

    /// Deletes objects named `name` that appeared during a failed upload. Best effort.
    private static func removeIncomplete(named name: String, in parentID: UInt32, storageID: UInt32,
                                         keeping: Set<UInt32>, on device: any MTPDevice) {
        guard let entries = try? device.listFolder(storageID: storageID, folderID: parentID) else { return }
        for entry in entries where entry.name == name && !keeping.contains(entry.objectID) {
            try? device.delete(objectID: entry.objectID)
        }
    }
}

/// A local file or folder to upload; `components` is the path relative to the upload's parent,
/// starting with the source's own name.
struct LocalItem {
    let components: [String]
    let url: URL
    let isDirectory: Bool
    let size: UInt64

    /// Pre-order list (folders before their contents), hidden files skipped.
    static func scan(_ source: URL) throws -> [LocalItem] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        let rootValues = try source.resourceValues(forKeys: keys)
        let rootIsDirectory = rootValues.isDirectory ?? false
        var items = [LocalItem(components: [source.lastPathComponent], url: source, isDirectory: rootIsDirectory,
                               size: rootIsDirectory ? 0 : UInt64(rootValues.fileSize ?? 0))]
        guard rootIsDirectory else { return items }

        // Resolve symlinks (/var → /private/var) so relative paths are computed consistently.
        let rootDepth = source.resolvingSymlinksInPath().pathComponents.count
        guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: Array(keys),
                                                              options: [.skipsHiddenFiles]) else { return items }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            let isDirectory = values.isDirectory ?? false
            let relative = url.resolvingSymlinksInPath().pathComponents.dropFirst(rootDepth)
            items.append(LocalItem(components: [source.lastPathComponent] + relative, url: url,
                                   isDirectory: isDirectory, size: isDirectory ? 0 : UInt64(values.fileSize ?? 0)))
        }
        return items
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/MTPKit --filter UploadTests`
Expected: 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add -A Packages/MTPKit
git commit -m "feat(MTPKit): uploads with space/conflict checks, folder trees and cleanup"
```

---

### Task 8: `MTPService` protocol and `LocalMTPService` engine

**Files:**
- Create: `Packages/MTPKit/Sources/MTPKit/MTPService.swift`
- Create: `Packages/MTPKit/Sources/MTPKit/LocalMTPService.swift`
- Test: `Packages/MTPKit/Tests/MTPKitTests/LocalMTPServiceTests.swift`

**Interfaces:**
- Consumes: `DeviceProvider`, `DeviceWorker`, `Transfers` (Tasks 4–7)
- Produces:
  - `enum ServiceEvent: Codable, Sendable, Equatable` with the cases:
    - `devicesChanged([DeviceInfo])`
    - `progress(jobID: UUID, done: UInt64, total: UInt64)`
    - `interrupted`
  - `protocol MTPService: Sendable`. Every method is `async`:
    - `setEventHandler(_ handler: @escaping @Sendable (ServiceEvent) -> Void)`
    - `devices() throws -> [DeviceInfo]`
    - `storages(deviceID:) throws -> [StorageInfo]`
    - `list(_ folder: FolderRef) throws -> [FileEntry]`
    - `download(jobID: UUID, entry: FileEntry, deviceID: DeviceID, into directory: URL) throws -> URL`
    - `upload(jobID: UUID, fileURL: URL, to folder: FolderRef) throws -> FileEntry`
    - `createFolder(named: String, in folder: FolderRef) throws -> FileEntry`
    - `rename(objectID: UInt32, deviceID: DeviceID, to newName: String) throws`
    - `delete(objectID: UInt32, deviceID: DeviceID) throws`
    - `cancel(jobID: UUID)`
    - `restart()`
  - `actor LocalMTPService: MTPService` with:
    - `init(provider: any DeviceProvider)`
    - `rescan() async`
    - `hasUnavailableDevices: Bool`

**Behavior:**
- **`devices()`:** runs a first `rescan()` if none has happened yet, and returns the devices sorted by `id`.
- **`rescan()`:**
  - Detached devices: their worker is shut down with `.deviceDisconnected` and they are removed.
  - New or previously unavailable devices: opened off the actor.
  - The method always emits `.devicesChanged`.
- **`restart()`:** shuts down all workers with `.serviceInterrupted`, emits `.interrupted`, then rescans.
- **Transfers:**
  - They run at `.transfer` priority. Everything else runs at `.interactive`.
  - A cancelled job throws `.cancelled` at its next progress callback, or immediately if it hasn't started.
  - Progress events are throttled to 10 per second per job, and the final one is always sent.

- [ ] **Step 1: Write the failing tests**

`Packages/MTPKit/Tests/MTPKitTests/LocalMTPServiceTests.swift`:

```swift
import Foundation
import Testing
@testable import MTPKit

@Suite struct LocalMTPServiceTests {
    let provider = FakeDeviceProvider()
    let device = FakeDevice(id: "p1", chunkSize: 1024, chunkDelay: 0.005)
    let events = Log<ServiceEvent>()

    private func makeService() async -> LocalMTPService {
        let service = LocalMTPService(provider: provider)
        let events = self.events
        await service.setEventHandler { events.append($0) }
        return service
    }

    @Test func listsReadyAndUnavailableDevices() async throws {
        provider.attach(device)
        provider.attachUnavailable(AttachedDevice(id: "p2", manufacturer: "Samsung", model: "S25"), error: .deviceLocked)
        let service = await makeService()
        let devices = try await service.devices()
        #expect(devices.map(\.id) == ["p1", "p2"])
        #expect(devices[0].state == .ready)
        #expect(devices[1].state == .unavailable(.deviceLocked))
        #expect(await service.hasUnavailableDevices)
        #expect(events.items.contains(.devicesChanged(devices)))
        await #expect(throws: MTPError.deviceLocked) { try await service.storages(deviceID: "p2") }
    }

    @Test func unavailableDeviceBecomesReadyOnRescan() async throws {
        provider.attachUnavailable(AttachedDevice(id: "p1", manufacturer: "Google", model: "Pixel 9"), error: .deviceLocked)
        let service = await makeService()
        _ = try await service.devices()
        provider.attach(device)
        await service.rescan()
        #expect(try await service.devices().first?.state == .ready)
        #expect(!(await service.hasUnavailableDevices))
    }

    @Test func listsFolders() async throws {
        provider.attach(device)
        device.addFolder("DCIM")
        let service = await makeService()
        _ = try await service.devices()
        let entries = try await service.list(FolderRef(deviceID: "p1", storageID: 1))
        #expect(entries.map(\.name) == ["DCIM"])
    }

    @Test func detachFailsInFlightOperation() async throws {
        provider.attach(device)
        let service = await makeService()
        _ = try await service.devices()
        device.inject(.hang)
        let listing = Task { try await service.list(FolderRef(deviceID: "p1", storageID: 1)) }
        try await Task.sleep(for: .milliseconds(50))
        provider.detach("p1")
        await service.rescan()
        await #expect(throws: MTPError.deviceDisconnected) { try await listing.value }
        #expect(try await service.devices().isEmpty)
        await #expect(throws: MTPError.deviceDisconnected) { try await service.storages(deviceID: "p1") }
        device.releaseHang()
    }

    @Test func restartInterruptsHungOperationAndReopens() async throws {
        provider.attach(device)
        let service = await makeService()
        _ = try await service.devices()
        device.inject(.hang)
        let listing = Task { try await service.list(FolderRef(deviceID: "p1", storageID: 1)) }
        try await Task.sleep(for: .milliseconds(50))
        await service.restart()
        await #expect(throws: MTPError.serviceInterrupted) { try await listing.value }
        #expect(events.items.contains(.interrupted))
        #expect(provider.openCount("p1") == 2)
        device.releaseHang()
        #expect(try await service.list(FolderRef(deviceID: "p1", storageID: 1)).isEmpty)
    }

    @Test func downloadReportsProgressAndCanBeCancelled() async throws {
        provider.attach(device)
        let file = device.addFile("big.bin", data: Data(count: 200 * 1024))
        let service = await makeService()
        _ = try await service.devices()
        let dir = try makeTempDirectory()
        let job = UUID()
        let download = Task { try await service.download(jobID: job, entry: file, deviceID: "p1", into: dir) }
        let events = self.events
        try await eventually { events.items.contains { if case .progress(job, _, _) = $0 { true } else { false } } }
        await service.cancel(jobID: job)
        await #expect(throws: MTPError.cancelled) { try await download.value }
        #expect(try contents(of: dir).isEmpty)
    }

    @Test func downloadCompletesWithFinalProgress() async throws {
        provider.attach(device)
        let file = device.addFile("small.bin", data: Data(count: 4096))
        let service = await makeService()
        _ = try await service.devices()
        let job = UUID()
        let url = try await service.download(jobID: job, entry: file, deviceID: "p1", into: try makeTempDirectory())
        #expect(try Data(contentsOf: url).count == 4096)
        #expect(events.items.contains(.progress(jobID: job, done: 4096, total: 4096)))
    }

    @Test func cancelBeforeStartSkipsTransfer() async throws {
        provider.attach(device)
        let file = device.addFile("a.bin", data: Data(count: 4096))
        let service = await makeService()
        _ = try await service.devices()
        device.inject(.hang)
        let blocker = Task { try await service.list(FolderRef(deviceID: "p1", storageID: 1)) }
        try await Task.sleep(for: .milliseconds(50))
        let dir = try makeTempDirectory()
        let job = UUID()
        let download = Task { try await service.download(jobID: job, entry: file, deviceID: "p1", into: dir) }
        try await Task.sleep(for: .milliseconds(20))
        await service.cancel(jobID: job)
        device.releaseHang()
        _ = try await blocker.value
        await #expect(throws: MTPError.cancelled) { try await download.value }
        #expect(try contents(of: dir).isEmpty)
        let events = self.events
        #expect(!events.items.contains { if case .progress(job, _, _) = $0 { true } else { false } })
    }

    @Test func mutationsReachTheDevice() async throws {
        provider.attach(device)
        let service = await makeService()
        _ = try await service.devices()
        let folder = FolderRef(deviceID: "p1", storageID: 1)
        let created = try await service.createFolder(named: "New", in: folder)
        try await service.rename(objectID: created.objectID, deviceID: "p1", to: "Renamed")
        #expect(try await service.list(folder).map(\.name) == ["Renamed"])
        try await service.delete(objectID: created.objectID, deviceID: "p1")
        #expect(try await service.list(folder).isEmpty)
    }

    @Test func uploadsIntoFolder() async throws {
        provider.attach(device)
        let service = await makeService()
        _ = try await service.devices()
        let file = try makeTempDirectory().appendingPathComponent("a.txt")
        try Data("hi".utf8).write(to: file)
        let entry = try await service.upload(jobID: UUID(), fileURL: file, to: FolderRef(deviceID: "p1", storageID: 1))
        #expect(device.data(of: entry.objectID) == Data("hi".utf8))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/MTPKit --filter LocalMTPServiceTests`
Expected: compile error `cannot find 'LocalMTPService' in scope`.

- [ ] **Step 3: Implement `MTPService.swift`**

```swift
import Foundation

public enum ServiceEvent: Codable, Sendable, Equatable {
    case devicesChanged([DeviceInfo])
    case progress(jobID: UUID, done: UInt64, total: UInt64)
    /// The service lost its state (helper restarted). In-flight calls have failed.
    case interrupted
}

/// Everything the app needs from the phone layer. Implemented in-process by `LocalMTPService`
/// (tests, previews, inside MTPHelper) and over XPC by `XPCMTPService`.
public protocol MTPService: Sendable {
    func setEventHandler(_ handler: @escaping @Sendable (ServiceEvent) -> Void) async
    func devices() async throws -> [DeviceInfo]
    func storages(deviceID: DeviceID) async throws -> [StorageInfo]
    func list(_ folder: FolderRef) async throws -> [FileEntry]
    func download(jobID: UUID, entry: FileEntry, deviceID: DeviceID, into directory: URL) async throws -> URL
    func upload(jobID: UUID, fileURL: URL, to folder: FolderRef) async throws -> FileEntry
    func createFolder(named name: String, in folder: FolderRef) async throws -> FileEntry
    func rename(objectID: UInt32, deviceID: DeviceID, to newName: String) async throws
    func delete(objectID: UInt32, deviceID: DeviceID) async throws
    func cancel(jobID: UUID) async
    /// Abandons all device state and in-flight calls, then reconnects. Used by watchdogs.
    func restart() async
}
```

- [ ] **Step 4: Implement `LocalMTPService.swift`**

```swift
import Foundation

public actor LocalMTPService: MTPService {
    private let provider: any DeviceProvider
    private var workers: [DeviceID: DeviceWorker] = [:]
    private var infos: [DeviceID: DeviceInfo] = [:]
    private var opening: Set<DeviceID> = []
    private var lastAttached: Set<DeviceID> = []
    private var hasScanned = false
    private var eventHandler: (@Sendable (ServiceEvent) -> Void)?
    private let cancellations = CancellationRegistry()

    public init(provider: any DeviceProvider) {
        self.provider = provider
    }

    public var hasUnavailableDevices: Bool {
        infos.values.contains { $0.state != .ready }
    }

    public func setEventHandler(_ handler: @escaping @Sendable (ServiceEvent) -> Void) {
        eventHandler = handler
    }

    public func devices() async throws -> [DeviceInfo] {
        if !hasScanned { await rescan() }
        return sortedDevices()
    }

    public func rescan() async {
        hasScanned = true
        let attached = provider.attachedDevices()
        lastAttached = Set(attached.map(\.id))

        for id in Array(infos.keys) where !lastAttached.contains(id) {
            workers.removeValue(forKey: id)?.shutdown(reason: .deviceDisconnected)
            infos[id] = nil
        }

        for device in attached where workers[device.id] == nil && !opening.contains(device.id) {
            opening.insert(device.id)
            let provider = self.provider
            let result = await Task.detached { () -> Result<any MTPDevice, MTPError> in
                do { return .success(try provider.open(device)) } catch { return .failure(MTPError.from(error)) }
            }.value
            opening.remove(device.id)

            switch result {
            case .success(let opened):
                guard lastAttached.contains(device.id) else { opened.close(); continue } // unplugged while opening
                workers[device.id] = DeviceWorker(device: opened, name: device.model)
                infos[device.id] = opened.info
            case .failure(let error):
                infos[device.id] = DeviceInfo(id: device.id, manufacturer: device.manufacturer,
                                              model: device.model, state: .unavailable(error))
            }
        }
        emit(.devicesChanged(sortedDevices()))
    }

    public func restart() async {
        for worker in workers.values { worker.shutdown(reason: .serviceInterrupted) }
        workers.removeAll()
        infos.removeAll()
        emit(.interrupted)
        await rescan()
    }

    public func storages(deviceID: DeviceID) async throws -> [StorageInfo] {
        try await worker(deviceID).perform(.interactive) { try $0.storages() }
    }

    public func list(_ folder: FolderRef) async throws -> [FileEntry] {
        try await worker(folder.deviceID).perform(.interactive) {
            try $0.listFolder(storageID: folder.storageID, folderID: folder.folderID)
        }
    }

    public func createFolder(named name: String, in folder: FolderRef) async throws -> FileEntry {
        try await worker(folder.deviceID).perform(.interactive) {
            try $0.createFolder(name: name, storageID: folder.storageID, parentID: folder.folderID)
        }
    }

    public func rename(objectID: UInt32, deviceID: DeviceID, to newName: String) async throws {
        try await worker(deviceID).perform(.interactive) { try $0.rename(objectID: objectID, to: newName) }
    }

    public func delete(objectID: UInt32, deviceID: DeviceID) async throws {
        try await worker(deviceID).perform(.interactive) { try $0.delete(objectID: objectID) }
    }

    public func download(jobID: UUID, entry: FileEntry, deviceID: DeviceID, into directory: URL) async throws -> URL {
        let reporter = ProgressReporter(jobID: jobID, registry: cancellations, handler: eventHandler)
        defer { cancellations.clear(jobID) }
        return try await worker(deviceID).perform(.transfer) { device in
            try reporter.checkCancelled()
            return try Transfers.download(entry, from: device, into: directory) { reporter.report(done: $0, total: $1) }
        }
    }

    public func upload(jobID: UUID, fileURL: URL, to folder: FolderRef) async throws -> FileEntry {
        let reporter = ProgressReporter(jobID: jobID, registry: cancellations, handler: eventHandler)
        defer { cancellations.clear(jobID) }
        return try await worker(folder.deviceID).perform(.transfer) { device in
            try reporter.checkCancelled()
            return try Transfers.upload(fileURL, to: device, storageID: folder.storageID, parentID: folder.folderID) {
                reporter.report(done: $0, total: $1)
            }
        }
    }

    public func cancel(jobID: UUID) {
        cancellations.cancel(jobID)
    }

    private func worker(_ id: DeviceID) throws -> DeviceWorker {
        if let worker = workers[id] { return worker }
        if case .unavailable(let error)? = infos[id]?.state { throw error }
        throw MTPError.deviceDisconnected
    }

    private func sortedDevices() -> [DeviceInfo] {
        infos.values.sorted { $0.id < $1.id }
    }

    private func emit(_ event: ServiceEvent) {
        eventHandler?(event)
    }
}

final class CancellationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled: Set<UUID> = []
    func cancel(_ id: UUID) { lock.withLock { _ = cancelled.insert(id) } }
    func isCancelled(_ id: UUID) -> Bool { lock.withLock { cancelled.contains(id) } }
    func clear(_ id: UUID) { lock.withLock { _ = cancelled.remove(id) } }
}

/// Used only on the DeviceWorker thread of the job it belongs to.
final class ProgressReporter: @unchecked Sendable {
    private let jobID: UUID
    private let registry: CancellationRegistry
    private let handler: (@Sendable (ServiceEvent) -> Void)?
    private var lastEmit: UInt64 = 0
    private static let interval: UInt64 = 100_000_000 // 10 updates per second

    init(jobID: UUID, registry: CancellationRegistry, handler: (@Sendable (ServiceEvent) -> Void)?) {
        self.jobID = jobID
        self.registry = registry
        self.handler = handler
    }

    func checkCancelled() throws {
        if registry.isCancelled(jobID) { throw MTPError.cancelled }
    }

    func report(done: UInt64, total: UInt64) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        if done >= total || now - lastEmit >= Self.interval {
            lastEmit = now
            handler?(.progress(jobID: jobID, done: done, total: total))
        }
        return !registry.isCancelled(jobID)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path Packages/MTPKit --filter LocalMTPServiceTests`
Expected: 10 tests pass.

- [ ] **Step 6: Run the whole package suite**

Run: `swift test --package-path Packages/MTPKit`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add -A Packages/MTPKit
git commit -m "feat(MTPKit): MTPService protocol and LocalMTPService engine"
```

---

### Task 9: XPC bridge: endpoint, client, codec

**Files:**
- Create: `Packages/MTPKit/Sources/MTPKit/XPC/XPCMessages.swift`
- Create: `Packages/MTPKit/Sources/MTPKit/XPC/MTPXPCEndpoint.swift`
- Create: `Packages/MTPKit/Sources/MTPKit/XPC/XPCMTPService.swift`
- Test: `Packages/MTPKit/Tests/MTPKitTests/XPCTests.swift`

**Interfaces:**
- Consumes: `MTPService`, `ServiceEvent`, `LocalMTPService`, `OnceContinuation`, `Unchecked` (Tasks 3, 8)
- Produces:
  - `@objc protocol MTPXPCProtocol { func call(_ request: Data, reply: @escaping @Sendable (Data) -> Void) }`
  - `@objc protocol MTPXPCEventsProtocol { func event(_ payload: Data) }`
  - `final class MTPXPCEndpoint` with `static func accept(_ connection: NSXPCConnection, service: any MTPService)`, called from the listener delegate
  - `final class XPCMTPService: MTPService` with `init(makeConnection: @escaping @Sendable () -> NSXPCConnection)` and `static func helper() -> XPCMTPService`

**Behavior:**
- **One generic RPC:** `call` carries a JSON-encoded `XPCRequest` and returns a JSON-encoded `XPCResponse`.
- **Errors:** server-side errors travel as `XPCResponse.failure(MTPError)`. On the client, any connection error during a call becomes `.serviceInterrupted`.
- **Restart and interruption:**
  - `restart()` kills the remote process (when it isn't this process) and invalidates the connection. The next call reconnects, and launchd relaunches the helper.
  - Connection interruption or invalidation delivers `.interrupted` to the event handler.

- [ ] **Step 1: Write the failing tests**

`Packages/MTPKit/Tests/MTPKitTests/XPCTests.swift`:

```swift
import Foundation
import Testing
@testable import MTPKit

/// Hosts an MTPService behind an in-process anonymous XPC listener.
final class XPCTestHost: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    let service: any MTPService

    init(service: any MTPService) {
        self.service = service
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        MTPXPCEndpoint.accept(connection, service: service)
        return true
    }

    func makeClient() -> XPCMTPService {
        let endpoint = Unchecked(listener.endpoint)
        return XPCMTPService { NSXPCConnection(listenerEndpoint: endpoint.value) }
    }
}

@Suite struct XPCTests {
    let provider = FakeDeviceProvider()
    let device = FakeDevice(id: "p1")

    private func makeClient() -> (XPCMTPService, XPCTestHost) {
        provider.attach(device)
        let host = XPCTestHost(service: LocalMTPService(provider: provider))
        return (host.makeClient(), host)
    }

    @Test func listsDevicesAndFolders() async throws {
        device.addFolder("DCIM")
        let (client, host) = makeClient()
        let devices = try await client.devices()
        #expect(devices.map(\.id) == ["p1"])
        #expect(try await client.storages(deviceID: "p1").first?.id == 1)
        #expect(try await client.list(FolderRef(deviceID: "p1", storageID: 1)).map(\.name) == ["DCIM"])
        withExtendedLifetime(host) {}
    }

    @Test func serverErrorsArriveTyped() async throws {
        let (client, host) = makeClient()
        await #expect(throws: MTPError.deviceDisconnected) { try await client.storages(deviceID: "nope") }
        withExtendedLifetime(host) {}
    }

    @Test func downloadDeliversProgressEvents() async throws {
        let file = device.addFile("a.bin", data: Data(count: 10_000))
        let (client, host) = makeClient()
        let events = Log<ServiceEvent>()
        await client.setEventHandler { events.append($0) }
        _ = try await client.devices()
        let job = UUID()
        let url = try await client.download(jobID: job, entry: file, deviceID: "p1", into: try makeTempDirectory())
        #expect(try Data(contentsOf: url).count == 10_000)
        try await eventually { events.items.contains(.progress(jobID: job, done: 10_000, total: 10_000)) }
        withExtendedLifetime(host) {}
    }

    @Test func restartFailsPendingCallAndReconnects() async throws {
        let (client, host) = makeClient()
        let events = Log<ServiceEvent>()
        await client.setEventHandler { events.append($0) }
        _ = try await client.devices()
        device.inject(.hang)
        let pending = Task { try await client.list(FolderRef(deviceID: "p1", storageID: 1)) }
        try await Task.sleep(for: .milliseconds(100))
        await client.restart()
        await #expect(throws: MTPError.serviceInterrupted) { try await pending.value }
        try await eventually { events.items.contains(.interrupted) }
        device.releaseHang()
        #expect(try await client.devices().map(\.id) == ["p1"])
        withExtendedLifetime(host) {}
    }

    @Test func requestsRoundTripThroughCodec() throws {
        let request = XPCRequest.upload(jobID: UUID(), fileURL: URL(fileURLWithPath: "/tmp/a b.txt"),
                                        folder: FolderRef(deviceID: "d", storageID: 2, folderID: 9))
        let decoded = try XPCCodec.decode(XPCRequest.self, from: XPCCodec.encode(request))
        #expect(decoded == request)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/MTPKit --filter XPCTests`
Expected: compile error `cannot find 'MTPXPCEndpoint' in scope`.

- [ ] **Step 3: Implement `XPC/XPCMessages.swift`**

```swift
import Foundation

@objc public protocol MTPXPCProtocol {
    /// One generic RPC: `request` is a JSON `XPCRequest`, the reply a JSON `XPCResponse`.
    func call(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

@objc public protocol MTPXPCEventsProtocol {
    /// `payload` is a JSON `ServiceEvent`.
    func event(_ payload: Data)
}

enum XPCRequest: Codable, Sendable, Equatable {
    case devices
    case storages(deviceID: DeviceID)
    case list(FolderRef)
    case download(jobID: UUID, entry: FileEntry, deviceID: DeviceID, directory: URL)
    case upload(jobID: UUID, fileURL: URL, folder: FolderRef)
    case createFolder(name: String, folder: FolderRef)
    case rename(objectID: UInt32, deviceID: DeviceID, newName: String)
    case delete(objectID: UInt32, deviceID: DeviceID)
    case cancel(jobID: UUID)
}

enum XPCResponse: Codable, Sendable {
    case devices([DeviceInfo])
    case storages([StorageInfo])
    case entries([FileEntry])
    case entry(FileEntry)
    case url(URL)
    case ok
    case failure(MTPError)
}

enum XPCCodec {
    static func encode<T: Encodable>(_ value: T) -> Data {
        do { return try JSONEncoder().encode(value) } catch { preconditionFailure("XPC encode failed: \(error)") }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
```

- [ ] **Step 4: Implement `XPC/MTPXPCEndpoint.swift`**

```swift
import Foundation

/// Helper-side adapter: decodes requests, calls the wrapped service, forwards events to the app.
public final class MTPXPCEndpoint: NSObject, MTPXPCProtocol, @unchecked Sendable {
    private let service: any MTPService

    private init(service: any MTPService) {
        self.service = service
    }

    /// Configures and resumes an accepted connection. Call from `listener(_:shouldAcceptNewConnection:)`.
    public static func accept(_ connection: NSXPCConnection, service: any MTPService) {
        connection.exportedInterface = NSXPCInterface(with: MTPXPCProtocol.self)
        connection.exportedObject = MTPXPCEndpoint(service: service)
        connection.remoteObjectInterface = NSXPCInterface(with: MTPXPCEventsProtocol.self)
        let events = Unchecked(connection.remoteObjectProxy as? MTPXPCEventsProtocol)
        connection.resume()
        Task {
            await service.setEventHandler { event in
                events.value?.event(XPCCodec.encode(event))
            }
        }
    }

    public func call(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        let service = self.service
        Task {
            let response: XPCResponse
            do {
                response = try await Self.handle(XPCCodec.decode(XPCRequest.self, from: request), service: service)
            } catch {
                response = .failure(MTPError.from(error))
            }
            reply(XPCCodec.encode(response))
        }
    }

    private static func handle(_ request: XPCRequest, service: any MTPService) async throws -> XPCResponse {
        switch request {
        case .devices:
            return .devices(try await service.devices())
        case .storages(let deviceID):
            return .storages(try await service.storages(deviceID: deviceID))
        case .list(let folder):
            return .entries(try await service.list(folder))
        case .download(let jobID, let entry, let deviceID, let directory):
            return .url(try await service.download(jobID: jobID, entry: entry, deviceID: deviceID, into: directory))
        case .upload(let jobID, let fileURL, let folder):
            return .entry(try await service.upload(jobID: jobID, fileURL: fileURL, to: folder))
        case .createFolder(let name, let folder):
            return .entry(try await service.createFolder(named: name, in: folder))
        case .rename(let objectID, let deviceID, let newName):
            try await service.rename(objectID: objectID, deviceID: deviceID, to: newName)
            return .ok
        case .delete(let objectID, let deviceID):
            try await service.delete(objectID: objectID, deviceID: deviceID)
            return .ok
        case .cancel(let jobID):
            await service.cancel(jobID: jobID)
            return .ok
        }
    }
}
```

- [ ] **Step 5: Implement `XPC/XPCMTPService.swift`**

```swift
import Foundation

/// App-side MTPService that forwards every call to MTPHelper.xpc.
public final class XPCMTPService: MTPService, @unchecked Sendable {
    private let makeConnection: @Sendable () -> NSXPCConnection
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private let sink = EventSink()

    public init(makeConnection: @escaping @Sendable () -> NSXPCConnection) {
        self.makeConnection = makeConnection
    }

    public static func helper() -> XPCMTPService {
        XPCMTPService { NSXPCConnection(serviceName: MTPHelperConstants.serviceName) }
    }

    public func setEventHandler(_ handler: @escaping @Sendable (ServiceEvent) -> Void) async {
        sink.setHandler(handler)
    }

    public func devices() async throws -> [DeviceInfo] {
        guard case .devices(let devices) = try await send(.devices) else { throw MTPError.unexpectedResponse }
        return devices
    }

    public func storages(deviceID: DeviceID) async throws -> [StorageInfo] {
        guard case .storages(let storages) = try await send(.storages(deviceID: deviceID)) else { throw MTPError.unexpectedResponse }
        return storages
    }

    public func list(_ folder: FolderRef) async throws -> [FileEntry] {
        guard case .entries(let entries) = try await send(.list(folder)) else { throw MTPError.unexpectedResponse }
        return entries
    }

    public func download(jobID: UUID, entry: FileEntry, deviceID: DeviceID, into directory: URL) async throws -> URL {
        let request = XPCRequest.download(jobID: jobID, entry: entry, deviceID: deviceID, directory: directory)
        guard case .url(let url) = try await send(request) else { throw MTPError.unexpectedResponse }
        return url
    }

    public func upload(jobID: UUID, fileURL: URL, to folder: FolderRef) async throws -> FileEntry {
        guard case .entry(let entry) = try await send(.upload(jobID: jobID, fileURL: fileURL, folder: folder)) else {
            throw MTPError.unexpectedResponse
        }
        return entry
    }

    public func createFolder(named name: String, in folder: FolderRef) async throws -> FileEntry {
        guard case .entry(let entry) = try await send(.createFolder(name: name, folder: folder)) else {
            throw MTPError.unexpectedResponse
        }
        return entry
    }

    public func rename(objectID: UInt32, deviceID: DeviceID, to newName: String) async throws {
        _ = try await send(.rename(objectID: objectID, deviceID: deviceID, newName: newName))
    }

    public func delete(objectID: UInt32, deviceID: DeviceID) async throws {
        _ = try await send(.delete(objectID: objectID, deviceID: deviceID))
    }

    public func cancel(jobID: UUID) async {
        _ = try? await send(.cancel(jobID: jobID))
    }

    /// Kills a hung helper and drops the connection; the next call relaunches it.
    public func restart() async {
        let old: NSXPCConnection? = lock.withLock {
            defer { connection = nil }
            return connection
        }
        guard let old else { return }
        let pid = old.processIdentifier
        if pid > 0 && pid != getpid() { kill(pid, SIGKILL) }
        old.invalidate()
    }

    // MARK: Internals

    private func currentConnection() -> NSXPCConnection {
        lock.withLock {
            if let connection { return connection }
            let connection = makeConnection()
            connection.remoteObjectInterface = NSXPCInterface(with: MTPXPCProtocol.self)
            connection.exportedInterface = NSXPCInterface(with: MTPXPCEventsProtocol.self)
            connection.exportedObject = sink
            let id = ObjectIdentifier(connection)
            connection.interruptionHandler = { [weak self] in self?.sink.deliver(.interrupted) }
            connection.invalidationHandler = { [weak self] in self?.connectionInvalidated(id) }
            connection.resume()
            self.connection = connection
            return connection
        }
    }

    private func connectionInvalidated(_ id: ObjectIdentifier) {
        lock.withLock {
            if let connection, ObjectIdentifier(connection) == id { self.connection = nil }
        }
        sink.deliver(.interrupted)
    }

    private func send(_ request: XPCRequest) async throws -> XPCResponse {
        let connection = Unchecked(currentConnection())
        let payload = XPCCodec.encode(request)
        let response: XPCResponse = try await withCheckedThrowingContinuation { continuation in
            let once = OnceContinuation(continuation)
            let proxy = connection.value.remoteObjectProxyWithErrorHandler { _ in
                once.resume(throwing: MTPError.serviceInterrupted)
            } as? MTPXPCProtocol
            guard let proxy else {
                once.resume(throwing: MTPError.serviceInterrupted)
                return
            }
            proxy.call(payload) { data in
                do { once.resume(returning: try XPCCodec.decode(XPCResponse.self, from: data)) }
                catch { once.resume(throwing: MTPError.from(error)) }
            }
        }
        if case .failure(let error) = response { throw error }
        return response
    }
}

private final class EventSink: NSObject, MTPXPCEventsProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (ServiceEvent) -> Void)?

    func setHandler(_ handler: @escaping @Sendable (ServiceEvent) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func deliver(_ event: ServiceEvent) {
        let handler = lock.withLock { self.handler }
        handler?(event)
    }

    func event(_ payload: Data) {
        if let event = try? XPCCodec.decode(ServiceEvent.self, from: payload) { deliver(event) }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --package-path Packages/MTPKit --filter XPCTests`
Expected: 5 tests pass.

- [ ] **Step 7: Commit**

```bash
git add -A Packages/MTPKit
git commit -m "feat(MTPKit): XPC endpoint and client with restart and typed errors"
```

---

### Task 10: libmtp device, provider, USB watcher, helper main

**Files:**
- Create: `MTPHelper/LibMTPDevice.swift`
- Create: `MTPHelper/LibMTPProvider.swift`
- Create: `MTPHelper/USBWatcher.swift`
- Modify: `MTPHelper/main.swift` (replace the stub)

**Interfaces:**
- Consumes:
  - `CLibMTP` (Task 1)
  - `MTPDevice`, `DeviceProvider`, `AttachedDevice` (Task 4)
  - `LocalMTPService` (Task 8)
  - `MTPXPCEndpoint` (Task 9)
- Produces: a working `MTPHelper.xpc` that serves `MTPXPCProtocol` with real phones. It has no unit tests, because hardware is required; it is verified on a real phone in Task 13.

**Notes:**
- **libmtp memory ownership:**
  - Strings from `LIBMTP_Get_*name` must be `free`d.
  - `LIBMTP_file_t` lists are freed with `LIBMTP_destroy_file_t`, which also frees `filename`. That is why we `strdup` it.
  - The raw device array is `free`d.
- **Root folder:** for creating folders and uploading, the parent is `0`. For listing, it is `LIBMTP_FILES_AND_FOLDERS_ROOT` (`0xFFFFFFFF`).
- **A locked Android phone** opens fine but reports no storage. We treat that as `.deviceLocked` and retry every 3 s.
- **When `LIBMTP_Open_Raw_Device_Uncached` fails on macOS,** the usual cause is that `ptpcamerad` (Image Capture) has claimed the USB interface. That maps to `.claimedByOtherProcess`. Plan 2 adds detection and the "Release" button.

- [ ] **Step 1: Implement `MTPHelper/LibMTPDevice.swift`**

```swift
import Foundation
import CLibMTP
import MTPKit

/// libmtp-backed phone. Not thread-safe; DeviceWorker confines every call to one thread.
final class LibMTPDevice: MTPDevice, @unchecked Sendable {
    let info: DeviceInfo
    private var handle: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?

    init(handle: UnsafeMutablePointer<LIBMTP_mtpdevice_t>, attached: AttachedDevice) {
        self.handle = handle
        let manufacturer = Self.take(LIBMTP_Get_Manufacturername(handle)) ?? attached.manufacturer
        let model = Self.take(LIBMTP_Get_Modelname(handle)) ?? attached.model
        info = DeviceInfo(id: attached.id, manufacturer: manufacturer, model: model, state: .ready)
    }

    func storages() throws -> [StorageInfo] {
        let h = try requireHandle()
        guard LIBMTP_Get_Storage(h, 0) == 0 else { throw lastError(h) } // 0 = LIBMTP_STORAGE_SORTBY_NOTSORTED
        var result: [StorageInfo] = []
        var storage = h.pointee.storage
        while let s = storage {
            result.append(StorageInfo(id: s.pointee.id,
                                      name: s.pointee.StorageDescription.map { String(cString: $0) } ?? "Storage",
                                      capacity: s.pointee.MaxCapacity,
                                      freeSpace: s.pointee.FreeSpaceInBytes))
            storage = s.pointee.next
        }
        return result
    }

    func listFolder(storageID: UInt32, folderID: UInt32) throws -> [FileEntry] {
        let h = try requireHandle()
        LIBMTP_Clear_Errorstack(h)
        var entries: [FileEntry] = []
        var file = LIBMTP_Get_Files_And_Folders(h, storageID, folderID)
        while let f = file {
            let next = f.pointee.next
            entries.append(FileEntry(
                objectID: f.pointee.item_id,
                parentID: f.pointee.parent_id,
                storageID: f.pointee.storage_id,
                name: f.pointee.filename.map { String(cString: $0) } ?? "",
                size: f.pointee.filesize,
                modified: f.pointee.modificationdate == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(f.pointee.modificationdate)),
                isFolder: f.pointee.filetype == LIBMTP_FILETYPE_FOLDER))
            LIBMTP_destroy_file_t(f)
            file = next
        }
        // An empty folder and a failure both return NULL; the error stack tells them apart.
        if entries.isEmpty, LIBMTP_Get_Errorstack(h) != nil { throw lastError(h) }
        return entries
    }

    func download(objectID: UInt32, to fileURL: URL, progress: ProgressHandler) throws {
        let h = try requireHandle()
        let rc = withProgressContext(progress) { context in
            fileURL.withUnsafeFileSystemRepresentation { path in
                LIBMTP_Get_File_To_File(h, objectID, path, { sent, total, data in
                    reportProgress(sent, total, data)
                }, context)
            }
        }
        if rc != 0 { throw lastError(h) }
    }

    func upload(from fileURL: URL, name: String, size: UInt64, storageID: UInt32, parentID: UInt32,
                progress: ProgressHandler) throws -> FileEntry {
        let h = try requireHandle()
        guard let file = LIBMTP_new_file_t() else { throw MTPError.underlying(code: -1, message: "Out of memory") }
        defer { LIBMTP_destroy_file_t(file) } // also frees filename
        file.pointee.filename = strdup(name)
        file.pointee.filesize = size
        file.pointee.filetype = LIBMTP_FILETYPE_UNKNOWN
        file.pointee.parent_id = Self.mtpParent(parentID)
        file.pointee.storage_id = storageID
        let rc = withProgressContext(progress) { context in
            fileURL.withUnsafeFileSystemRepresentation { path in
                LIBMTP_Send_File_From_File(h, path, file, { sent, total, data in
                    reportProgress(sent, total, data)
                }, context)
            }
        }
        if rc != 0 { throw lastError(h) }
        return FileEntry(objectID: file.pointee.item_id, parentID: parentID, storageID: storageID, name: name,
                         size: size, modified: Date(), isFolder: false)
    }

    func createFolder(name: String, storageID: UInt32, parentID: UInt32) throws -> FileEntry {
        let h = try requireHandle()
        let cName = strdup(name)
        defer { free(cName) }
        let id = LIBMTP_Create_Folder(h, cName, Self.mtpParent(parentID), storageID)
        if id == 0 { throw lastError(h) }
        return FileEntry(objectID: id, parentID: parentID, storageID: storageID, name: name, size: 0,
                         modified: Date(), isFolder: true)
    }

    func rename(objectID: UInt32, to newName: String) throws {
        let h = try requireHandle()
        let cName = strdup(newName)
        defer { free(cName) }
        if LIBMTP_Set_Object_Filename(h, objectID, cName) != 0 { throw lastError(h) }
    }

    func delete(objectID: UInt32) throws {
        let h = try requireHandle()
        if LIBMTP_Delete_Object(h, objectID) != 0 { throw lastError(h) }
    }

    func close() {
        if let handle { LIBMTP_Release_Device(handle) }
        handle = nil
    }

    // MARK: Internals

    private func requireHandle() throws -> UnsafeMutablePointer<LIBMTP_mtpdevice_t> {
        guard let handle else { throw MTPError.deviceDisconnected }
        return handle
    }

    /// libmtp uses 0 for "root" when creating objects, but 0xFFFFFFFF when listing.
    private static func mtpParent(_ parentID: UInt32) -> UInt32 {
        parentID == FileEntry.rootID ? 0 : parentID
    }

    private static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { free(pointer) }
        let string = String(cString: pointer)
        return string.isEmpty ? nil : string
    }

    private func lastError(_ h: UnsafeMutablePointer<LIBMTP_mtpdevice_t>) -> MTPError {
        defer { LIBMTP_Clear_Errorstack(h) }
        var last: (number: LIBMTP_error_number_t, text: String)?
        var error = LIBMTP_Get_Errorstack(h)
        while let e = error {
            last = (e.pointee.errornumber, e.pointee.error_text.map { String(cString: $0) } ?? "")
            error = e.pointee.next
        }
        guard let last else { return .underlying(code: -1, message: "Unknown libmtp error") }
        switch last.number {
        case LIBMTP_ERROR_CANCELLED: return .cancelled
        case LIBMTP_ERROR_NO_DEVICE_ATTACHED, LIBMTP_ERROR_USB_LAYER: return .deviceDisconnected
        case LIBMTP_ERROR_STORAGE_FULL: return .storageFull(needed: 0, available: 0)
        default: return .underlying(code: Int(last.number.rawValue), message: last.text)
        }
    }
}

// MARK: Progress bridging to libmtp's C callback

private final class ProgressBox {
    let handler: ProgressHandler
    init(_ handler: @escaping ProgressHandler) { self.handler = handler }
}

private func withProgressContext<R>(_ progress: ProgressHandler, _ body: (UnsafeRawPointer) -> R) -> R {
    withoutActuallyEscaping(progress) { escapable in
        let box = ProgressBox(escapable)
        return withExtendedLifetime(box) {
            body(UnsafeRawPointer(Unmanaged.passUnretained(box).toOpaque()))
        }
    }
}

/// Returns non-zero to make libmtp cancel the transfer.
private func reportProgress(_ sent: UInt64, _ total: UInt64, _ data: UnsafeRawPointer?) -> Int32 {
    guard let data else { return 0 }
    let box = Unmanaged<ProgressBox>.fromOpaque(data).takeUnretainedValue()
    return box.handler(sent, total) ? 0 : 1
}
```

- [ ] **Step 2: Implement `MTPHelper/LibMTPProvider.swift`**

```swift
import Foundation
import CLibMTP
import MTPKit

final class LibMTPProvider: DeviceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var raw: [DeviceID: LIBMTP_raw_device_t] = [:]

    func attachedDevices() -> [AttachedDevice] {
        var list: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var count: Int32 = 0
        guard LIBMTP_Detect_Raw_Devices(&list, &count) == LIBMTP_ERROR_NONE, let list else {
            lock.withLock { raw.removeAll() }
            return []
        }
        defer { free(list) }
        var found: [DeviceID: LIBMTP_raw_device_t] = [:]
        var devices: [AttachedDevice] = []
        for i in 0..<Int(count) {
            let r = list[i]
            let id = "\(String(r.bus_location, radix: 16))-\(r.devnum)"
            found[id] = r
            devices.append(AttachedDevice(id: id,
                                          manufacturer: r.device_entry.vendor.map { String(cString: $0) } ?? "",
                                          model: r.device_entry.product.map { String(cString: $0) } ?? "Android"))
        }
        lock.withLock { raw = found }
        return devices
    }

    func open(_ device: AttachedDevice) throws -> any MTPDevice {
        guard var r = lock.withLock({ raw[device.id] }) else { throw MTPError.deviceDisconnected }
        guard let handle = LIBMTP_Open_Raw_Device_Uncached(&r) else {
            // On macOS this almost always means ptpcamerad (Image Capture) holds the interface.
            throw MTPError.claimedByOtherProcess
        }
        let opened = LibMTPDevice(handle: handle, attached: device)
        // A locked Android phone opens but exposes no storage until unlocked.
        if (try? opened.storages())?.isEmpty ?? true {
            opened.close()
            throw MTPError.deviceLocked
        }
        return opened
    }
}
```

- [ ] **Step 3: Implement `MTPHelper/USBWatcher.swift`**

```swift
import Foundation
import IOKit
import IOKit.usb

/// Calls `onChange` on the main queue whenever any USB device appears or disappears.
final class USBWatcher: @unchecked Sendable {
    private let onChange: @MainActor () -> Void
    private var port: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            guard let context else { return }
            let watcher = Unmanaged<USBWatcher>.fromOpaque(context).takeUnretainedValue()
            USBWatcher.drain(iterator)
            MainActor.assumeIsolated { watcher.onChange() } // notifications are delivered on .main
        }
        _ = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostDevice"),
                                             callback, context, &addedIterator)
        Self.drain(addedIterator) // arms the notification
        _ = IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("IOUSBHostDevice"),
                                             callback, context, &removedIterator)
        Self.drain(removedIterator)
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let object = IOIteratorNext(iterator), object != 0 {
            IOObjectRelease(object)
        }
    }
}
```

- [ ] **Step 4: Replace `MTPHelper/main.swift`**

```swift
import Foundation
import CLibMTP
import MTPKit

/// Debounces USB events into rescans and retries locked/claimed phones every 3 seconds.
final class Rescanner: @unchecked Sendable {
    private let service: LocalMTPService
    private var pending: DispatchWorkItem?
    private let retryTimer = DispatchSource.makeTimerSource(queue: .main)

    init(service: LocalMTPService) {
        self.service = service
        retryTimer.schedule(deadline: .now() + 3, repeating: 3)
        retryTimer.setEventHandler { [service] in
            Task { if await service.hasUnavailableDevices { await service.rescan() } }
        }
        retryTimer.resume()
    }

    /// Main queue only.
    func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [service] in Task { await service.rescan() } }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service: LocalMTPService
    init(service: LocalMTPService) { self.service = service }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        MTPXPCEndpoint.accept(connection, service: service)
        return true
    }
}

LIBMTP_Init()
let service = LocalMTPService(provider: LibMTPProvider())
let rescanner = Rescanner(service: service)
let usbWatcher = USBWatcher { rescanner.schedule() }
let delegate = ListenerDelegate(service: service)
let listener = NSXPCListener.service()
listener.delegate = delegate
rescanner.schedule()
listener.resume() // never returns
```

- [ ] **Step 5: Build**

Run: `xcodegen generate && xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Debug -derivedDataPath DerivedData build 2>&1 | grep -E "error:|BUILD" | head -20`
Expected: `** BUILD SUCCEEDED **` with no `error:` lines. If the compiler rejects an imported libmtp constant's type (for example `LIBMTP_FILETYPE_FOLDER` comparison), compare with `.rawValue` on both sides; the probe compiled during planning confirmed these names import.

- [ ] **Step 6: Verify the helper links its dylibs from inside the bundle**

Run: `otool -L DerivedData/Build/Products/Debug/Tether.app/Contents/XPCServices/MTPHelper.xpc/Contents/MacOS/MTPHelper | grep -E "mtp|usb"`
Expected: `@rpath/libmtp.9.dylib`

- [ ] **Step 7: Commit**

```bash
git add MTPHelper
git commit -m "feat(helper): libmtp device/provider, USB hotplug watcher and XPC listener"
```

---

### Task 11: `DeviceStore`: devices, storages, cached listings

**Files:**
- Create: `Packages/MTPKit/Sources/TetherCore/DeviceStore.swift`
- Delete: `Packages/MTPKit/Sources/TetherCore/TetherCore.swift`, `Packages/MTPKit/Tests/TetherCoreTests/ScaffoldTests.swift`
- Test: `Packages/MTPKit/Tests/TetherCoreTests/DeviceStoreTests.swift`, `Packages/MTPKit/Tests/TetherCoreTests/TestSupport.swift`

**Interfaces:**
- Consumes: `MTPService`, `LocalMTPService`, `FakeDeviceProvider`, `withTimeout` (MTPKit)
- Produces: `@MainActor @Observable final class DeviceStore`, with:
  - `init(service: any MTPService)`
  - Read-only state:
    - `devices: [DeviceInfo]`
    - `storages: [DeviceID: [StorageInfo]]`
    - `listings: [FolderRef: Listing]`
  - `listTimeout: Duration` (default 15 s)
  - Methods, all `async` except `apply` and `storage(for:)`:
    - `reloadDevices()`
    - `apply(_ devices: [DeviceInfo])`
    - `loadStorages(_ id: DeviceID)`
    - `refresh(_ folder: FolderRef)`
    - `createFolder(named:in:) throws -> FileEntry`
    - `rename(_ entry: FileEntry, in folder: FolderRef, to newName: String) throws`
    - `delete(_ entries: [FileEntry], in folder: FolderRef) throws`
    - `storage(for folder: FolderRef) -> StorageInfo?`
  - `struct Listing { entries: [FileEntry]; isUpdating: Bool; error: MTPError? }`

**Behavior:**
- `refresh` keeps any cached entries visible while `isUpdating` is true.
- If the listing doesn't answer within `listTimeout`, `refresh` restarts the service and sets `error = .timeout`.
- It never writes a listing for a device that has gone away.
- `apply` drops storages and listings of removed devices, and loads storages for newly ready devices.

- [ ] **Step 1: Write the failing tests**

`Packages/MTPKit/Tests/TetherCoreTests/TestSupport.swift`:

```swift
import Foundation
import Testing

func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("TetherCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
func eventually(timeout: Duration = .seconds(3), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("condition not met within \(timeout)")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
```

`Packages/MTPKit/Tests/TetherCoreTests/DeviceStoreTests.swift`:

```swift
import Foundation
import Testing
import MTPKit
@testable import TetherCore

@MainActor
@Suite struct DeviceStoreTests {
    let provider = FakeDeviceProvider()
    let device = FakeDevice(id: "p1")
    var folder: FolderRef { FolderRef(deviceID: "p1", storageID: 1) }

    private func makeStore() -> (DeviceStore, LocalMTPService) {
        provider.attach(device)
        let service = LocalMTPService(provider: provider)
        return (DeviceStore(service: service), service)
    }

    @Test func reloadLoadsDevicesAndStorages() async throws {
        let (store, _) = makeStore()
        await store.reloadDevices()
        #expect(store.devices.map(\.id) == ["p1"])
        try await eventually { store.storages["p1"]?.first?.id == 1 }
        #expect(store.storage(for: folder)?.name == "Internal shared storage")
    }

    @Test func refreshCachesListing() async throws {
        device.addFolder("DCIM")
        let (store, _) = makeStore()
        await store.reloadDevices()
        await store.refresh(folder)
        #expect(store.listings[folder] == DeviceStore.Listing(entries: try device.listFolder(storageID: 1, folderID: FileEntry.rootID),
                                                              isUpdating: false, error: nil))
    }

    @Test func refreshKeepsCachedEntriesWhileUpdating() async throws {
        device.addFolder("DCIM")
        let (store, _) = makeStore()
        await store.reloadDevices()
        await store.refresh(folder)
        device.inject(.hang)
        let refreshing = Task { await store.refresh(folder) }
        try await eventually { store.listings[folder]?.isUpdating == true }
        #expect(store.listings[folder]?.entries.map(\.name) == ["DCIM"])
        device.releaseHang()
        await refreshing.value
        #expect(store.listings[folder]?.isUpdating == false)
    }

    @Test func removedDeviceDropsListings() async throws {
        let (store, _) = makeStore()
        await store.reloadDevices()
        await store.refresh(folder)
        #expect(store.listings[folder] != nil)
        store.apply([])
        #expect(store.listings.isEmpty)
        #expect(store.storages.isEmpty)
    }

    @Test func hungListingTimesOutAndRestartsService() async throws {
        let (store, _) = makeStore()
        store.listTimeout = .milliseconds(200)
        await store.reloadDevices()
        device.inject(.hang)
        await store.refresh(folder)
        #expect(store.listings[folder]?.error == .timeout)
        #expect(store.listings[folder]?.isUpdating == false)
        #expect(provider.openCount("p1") == 2)
        device.releaseHang()
    }

    @Test func mutationsRefreshTheFolder() async throws {
        let (store, _) = makeStore()
        await store.reloadDevices()
        let created = try await store.createFolder(named: "New", in: folder)
        #expect(store.listings[folder]?.entries.map(\.name) == ["New"])
        try await store.rename(created, in: folder, to: "Renamed")
        #expect(store.listings[folder]?.entries.map(\.name) == ["Renamed"])
        try await store.delete(store.listings[folder]!.entries, in: folder)
        #expect(store.listings[folder]?.entries.isEmpty == true)
    }
}
```

Delete `Packages/MTPKit/Sources/TetherCore/TetherCore.swift` and `Packages/MTPKit/Tests/TetherCoreTests/ScaffoldTests.swift`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/MTPKit --filter DeviceStoreTests`
Expected: compile error `cannot find 'DeviceStore' in scope`.

- [ ] **Step 3: Implement `DeviceStore.swift`**

```swift
import Foundation
import Observation
import MTPKit

@MainActor
@Observable
public final class DeviceStore {
    public struct Listing: Equatable, Sendable {
        public var entries: [FileEntry]
        public var isUpdating: Bool
        public var error: MTPError?
    }

    public private(set) var devices: [DeviceInfo] = []
    public private(set) var storages: [DeviceID: [StorageInfo]] = [:]
    public private(set) var listings: [FolderRef: Listing] = [:]
    public var listTimeout: Duration = .seconds(15)

    @ObservationIgnored private let service: any MTPService

    public init(service: any MTPService) {
        self.service = service
    }

    public func reloadDevices() async {
        apply((try? await service.devices()) ?? [])
    }

    public func apply(_ newDevices: [DeviceInfo]) {
        let readyBefore = Set(devices.filter { $0.state == .ready }.map(\.id))
        let readyNow = Set(newDevices.filter { $0.state == .ready }.map(\.id))
        devices = newDevices
        storages = storages.filter { readyNow.contains($0.key) }
        listings = listings.filter { readyNow.contains($0.key.deviceID) }
        for id in readyNow.subtracting(readyBefore) {
            Task { await loadStorages(id) }
        }
    }

    public func loadStorages(_ id: DeviceID) async {
        guard let list = try? await service.storages(deviceID: id), isReady(id) else { return }
        storages[id] = list
    }

    public func storage(for folder: FolderRef) -> StorageInfo? {
        storages[folder.deviceID]?.first { $0.id == folder.storageID }
    }

    public func refresh(_ folder: FolderRef) async {
        var listing = listings[folder] ?? Listing(entries: [], isUpdating: true, error: nil)
        listing.isUpdating = true
        listings[folder] = listing

        let service = self.service
        let result: Result<[FileEntry], MTPError>
        do {
            result = .success(try await withTimeout(listTimeout, onTimeout: { await service.restart() }) {
                try await service.list(folder)
            })
        } catch {
            result = .failure(MTPError.from(error))
        }

        guard isReady(folder.deviceID) || result.isTimeout else { listings[folder] = nil; return }
        switch result {
        case .success(let entries):
            listings[folder] = Listing(entries: entries, isUpdating: false, error: nil)
        case .failure(let error):
            listings[folder] = Listing(entries: listings[folder]?.entries ?? [], isUpdating: false, error: error)
        }
    }

    public func createFolder(named name: String, in folder: FolderRef) async throws -> FileEntry {
        let entry = try await service.createFolder(named: name, in: folder)
        await refresh(folder)
        return entry
    }

    public func rename(_ entry: FileEntry, in folder: FolderRef, to newName: String) async throws {
        do { try await service.rename(objectID: entry.objectID, deviceID: folder.deviceID, to: newName) }
        catch { await refresh(folder); throw error }
        await refresh(folder)
    }

    public func delete(_ entries: [FileEntry], in folder: FolderRef) async throws {
        do {
            for entry in entries { try await service.delete(objectID: entry.objectID, deviceID: folder.deviceID) }
        } catch {
            await refresh(folder)
            throw error
        }
        await refresh(folder)
    }

    private func isReady(_ id: DeviceID) -> Bool {
        devices.contains { $0.id == id && $0.state == .ready }
    }
}

private extension Result where Failure == MTPError {
    /// A timeout restarts the service, which briefly removes devices; keep the error visible anyway.
    var isTimeout: Bool { if case .failure(.timeout) = self { true } else { false } }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/MTPKit --filter DeviceStoreTests`
Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add -A Packages/MTPKit
git commit -m "feat(TetherCore): DeviceStore with cached listings and list watchdog"
```

---

### Task 12: `TransferQueue` and `AppModel`

**Files:**
- Create: `Packages/MTPKit/Sources/TetherCore/TransferQueue.swift`
- Create: `Packages/MTPKit/Sources/TetherCore/AppModel.swift`
- Test: `Packages/MTPKit/Tests/TetherCoreTests/TransferQueueTests.swift`, `AppModelTests.swift`

**Interfaces:**
- Consumes: `MTPService`, `ServiceEvent`, `DeviceStore` (Tasks 8, 11)
- Produces:
  - `@MainActor @Observable final class TransferQueue`, with:
    - `init(service:)`
    - Nested types: `Kind`, `State` and `Job`
    - Read-only state: `jobs: [Job]` and `hasActiveJobs`
    - `stallTimeout: Duration` (30 s)
    - `onJobFinished: (@MainActor (Job) -> Void)?`
    - Enqueue methods, both `@discardableResult -> UUID`:
      - `enqueueDownload(_:deviceID:into:completion:)`
      - `enqueueUpload(_:to:)`
    - Job control: `cancel(_:)`, `retry(_:)`, `updateProgress(attempt:done:total:)`
    - Watchdog: `startWatchdog(interval:)` and `checkForStalls(now:) async`
  - `TransferQueue.Kind`: `download(FileEntry, deviceID: DeviceID, directory: URL)` or `upload(URL, folder: FolderRef)`
  - `TransferQueue.State`: `queued`, `running`, `finished(URL?)`, `failed(MTPError)` or `cancelled`
  - `TransferQueue.Job` has `id`, `kind`, `state`, `done`, `total`, `name`, `deviceID`, `fraction` and `isActive`. Internally it also has `attempt: UUID` and `lastActivity`.
  - `@MainActor @Observable final class AppModel` with `init(service:)`, `devices: DeviceStore`, `transfers: TransferQueue` and `start() async`

**Behavior:**
- **Scheduling:**
  - At most one running job per device. Different devices run in parallel.
  - The next job starts when the previous one finishes.
- **Cancel:**
  - A queued job becomes `.cancelled` immediately.
  - For a running job, the service is asked to cancel it.
- **Retry:** `retry` gives the job a new `attempt` ID, so a late cancel of the old attempt can't affect it.
- **Watchdog:** if a running job has had no progress for `stallTimeout`, the service is restarted. The job then fails with `.serviceInterrupted`.
- **AppModel:**
  - It routes `.devicesChanged` to `DeviceStore.apply` and `.progress` to `updateProgress`.
  - `.interrupted` triggers `reloadDevices`.
  - After an upload finishes, it refreshes that folder's listing and the storage's free space.

- [ ] **Step 1: Write the failing tests**

`Packages/MTPKit/Tests/TetherCoreTests/TransferQueueTests.swift`:

```swift
import Foundation
import Testing
import MTPKit
@testable import TetherCore

@MainActor
@Suite struct TransferQueueTests {
    let provider = FakeDeviceProvider()
    let device = FakeDevice(id: "p1", chunkSize: 1024, chunkDelay: 0.002)

    private func makeQueue() async throws -> (TransferQueue, LocalMTPService) {
        provider.attach(device)
        let service = LocalMTPService(provider: provider)
        _ = try await service.devices()
        return (TransferQueue(service: service), service)
    }

    @Test func downloadFinishesAndCallsCompletion() async throws {
        let file = device.addFile("a.txt", data: Data("hello".utf8))
        let (queue, _) = try await makeQueue()
        let dir = try makeTempDirectory()
        var result: Result<URL?, MTPError>?
        queue.enqueueDownload(file, deviceID: "p1", into: dir) { result = $0 }
        try await eventually { result != nil }
        let url = try #require(try result?.get())
        #expect(try Data(contentsOf: url) == Data("hello".utf8))
        #expect(queue.jobs.first?.state == .finished(url))
    }

    @Test func jobsForSameDeviceRunOneAtATime() async throws {
        let a = device.addFile("a.bin", data: Data(count: 100_000))
        let b = device.addFile("b.bin", data: Data(count: 100_000))
        let (queue, _) = try await makeQueue()
        let dir = try makeTempDirectory()
        queue.enqueueDownload(a, deviceID: "p1", into: dir)
        queue.enqueueDownload(b, deviceID: "p1", into: dir)
        #expect(queue.jobs.map(\.state) == [.running, .queued])
        try await eventually { queue.jobs.allSatisfy { if case .finished = $0.state { true } else { false } } }
    }

    @Test func cancelQueuedJob() async throws {
        let a = device.addFile("a.bin", data: Data(count: 100_000))
        let b = device.addFile("b.bin", data: Data(count: 100_000))
        let (queue, _) = try await makeQueue()
        let dir = try makeTempDirectory()
        queue.enqueueDownload(a, deviceID: "p1", into: dir)
        var result: Result<URL?, MTPError>?
        let second = queue.enqueueDownload(b, deviceID: "p1", into: dir) { result = $0 }
        queue.cancel(second)
        #expect(queue.jobs[1].state == .cancelled)
        #expect(result == .failure(.cancelled))
        try await eventually { if case .finished = queue.jobs[0].state { true } else { false } }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["a.bin"])
    }

    @Test func cancelRunningJob() async throws {
        let file = device.addFile("big.bin", data: Data(count: 400_000))
        let (queue, service) = try await makeQueue()
        await service.setEventHandler { event in
            if case .progress(let attempt, let done, let total) = event {
                Task { @MainActor in queue.updateProgress(attempt: attempt, done: done, total: total) }
            }
        }
        let dir = try makeTempDirectory()
        let id = queue.enqueueDownload(file, deviceID: "p1", into: dir)
        try await eventually { queue.jobs[0].done > 0 }
        queue.cancel(id)
        try await eventually { queue.jobs[0].state == .cancelled }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func failedJobCanBeRetried() async throws {
        let file = device.addFile("a.txt", data: Data("x".utf8))
        let (queue, _) = try await makeQueue()
        device.inject(.fail(.deviceBusy))
        let id = queue.enqueueDownload(file, deviceID: "p1", into: try makeTempDirectory())
        try await eventually { queue.jobs[0].state == .failed(.deviceBusy) }
        queue.retry(id)
        try await eventually { if case .finished = queue.jobs[0].state { true } else { false } }
    }

    @Test func stalledJobTriggersRestart() async throws {
        let file = device.addFile("a.txt", data: Data("x".utf8))
        let (queue, _) = try await makeQueue()
        device.inject(.hang)
        queue.enqueueDownload(file, deviceID: "p1", into: try makeTempDirectory())
        try await Task.sleep(for: .milliseconds(50))
        await queue.checkForStalls(now: .now + .seconds(31))
        try await eventually { queue.jobs[0].state == .failed(.serviceInterrupted) }
        #expect(provider.openCount("p1") == 2)
        device.releaseHang()
    }

    @Test func noRestartWhileProgressing() async throws {
        let file = device.addFile("a.txt", data: Data("x".utf8))
        let (queue, _) = try await makeQueue()
        device.inject(.hang)
        queue.enqueueDownload(file, deviceID: "p1", into: try makeTempDirectory())
        await queue.checkForStalls(now: .now + .seconds(5))
        #expect(provider.openCount("p1") == 1)
        device.releaseHang()
        try await eventually { if case .finished = queue.jobs[0].state { true } else { false } }
    }

    @Test func uploadIsQueuedAndFinishes() async throws {
        let (queue, _) = try await makeQueue()
        let file = try makeTempDirectory().appendingPathComponent("up.txt")
        try Data("up".utf8).write(to: file)
        var finished: [TransferQueue.Job] = []
        queue.onJobFinished = { finished.append($0) }
        queue.enqueueUpload(file, to: FolderRef(deviceID: "p1", storageID: 1))
        try await eventually { finished.count == 1 }
        #expect(finished[0].state == .finished(nil))
        #expect(device.children(of: FileEntry.rootID).map(\.name) == ["up.txt"])
    }
}
```

`Packages/MTPKit/Tests/TetherCoreTests/AppModelTests.swift`:

```swift
import Foundation
import Testing
import MTPKit
@testable import TetherCore

@MainActor
@Suite struct AppModelTests {
    let provider = FakeDeviceProvider()
    let device = FakeDevice(id: "p1", chunkSize: 1024, chunkDelay: 0.002)

    @Test func startLoadsDevicesAndRoutesProgress() async throws {
        provider.attach(device)
        let file = device.addFile("big.bin", data: Data(count: 100_000))
        let model = AppModel(service: LocalMTPService(provider: provider))
        await model.start()
        #expect(model.devices.devices.map(\.id) == ["p1"])
        model.transfers.enqueueDownload(file, deviceID: "p1", into: try makeTempDirectory())
        try await eventually { model.transfers.jobs[0].done > 0 }
        try await eventually { if case .finished = model.transfers.jobs[0].state { true } else { false } }
        try await eventually { model.transfers.jobs[0].fraction == 1 }
    }

    @Test func deviceEventsUpdateStore() async throws {
        provider.attach(device)
        let service = LocalMTPService(provider: provider)
        let model = AppModel(service: service)
        await model.start()
        provider.detach("p1")
        await service.rescan()
        try await eventually { model.devices.devices.isEmpty }
    }

    @Test func finishedUploadRefreshesFolder() async throws {
        provider.attach(device)
        let model = AppModel(service: LocalMTPService(provider: provider))
        await model.start()
        let folder = FolderRef(deviceID: "p1", storageID: 1)
        await model.devices.refresh(folder)
        let file = try makeTempDirectory().appendingPathComponent("up.txt")
        try Data("up".utf8).write(to: file)
        model.transfers.enqueueUpload(file, to: folder)
        try await eventually { model.devices.listings[folder]?.entries.map(\.name) == ["up.txt"] }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Packages/MTPKit --filter "TransferQueueTests|AppModelTests"`
Expected: compile error `cannot find 'TransferQueue' in scope`.

- [ ] **Step 3: Implement `TransferQueue.swift`**

```swift
import Foundation
import Observation
import MTPKit

@MainActor
@Observable
public final class TransferQueue {
    public enum Kind: Equatable, Sendable {
        case download(FileEntry, deviceID: DeviceID, directory: URL)
        case upload(URL, folder: FolderRef)
    }

    public enum State: Equatable, Sendable {
        case queued, running, finished(URL?), failed(MTPError), cancelled
    }

    public struct Job: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let kind: Kind
        public internal(set) var state: State = .queued
        public internal(set) var done: UInt64 = 0
        public internal(set) var total: UInt64 = 0
        /// Identifies one run of the job to the service; changes on retry.
        var attempt = UUID()
        var lastActivity = ContinuousClock.now

        public var name: String {
            switch kind {
            case .download(let entry, _, _): entry.name
            case .upload(let url, _): url.lastPathComponent
            }
        }

        public var deviceID: DeviceID {
            switch kind {
            case .download(_, let deviceID, _): deviceID
            case .upload(_, let folder): folder.deviceID
            }
        }

        public var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
        public var isActive: Bool { state == .queued || state == .running }
    }

    public typealias Completion = @MainActor (Result<URL?, MTPError>) -> Void

    public private(set) var jobs: [Job] = []
    public var stallTimeout: Duration = .seconds(30)
    @ObservationIgnored public var onJobFinished: (@MainActor (Job) -> Void)?

    @ObservationIgnored private let service: any MTPService
    @ObservationIgnored private var completions: [UUID: Completion] = [:]
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    public init(service: any MTPService) {
        self.service = service
    }

    public var hasActiveJobs: Bool { jobs.contains { $0.isActive } }

    @discardableResult
    public func enqueueDownload(_ entry: FileEntry, deviceID: DeviceID, into directory: URL,
                                completion: Completion? = nil) -> UUID {
        enqueue(.download(entry, deviceID: deviceID, directory: directory), completion: completion)
    }

    @discardableResult
    public func enqueueUpload(_ url: URL, to folder: FolderRef) -> UUID {
        enqueue(.upload(url, folder: folder), completion: nil)
    }

    public func cancel(_ id: UUID) {
        guard let i = index(id) else { return }
        switch jobs[i].state {
        case .queued:
            finish(i, .cancelled)
        case .running:
            let attempt = jobs[i].attempt
            Task { await service.cancel(jobID: attempt) }
        default:
            break
        }
    }

    public func retry(_ id: UUID) {
        guard let i = index(id) else { return }
        switch jobs[i].state {
        case .failed, .cancelled:
            jobs[i].state = .queued
            jobs[i].done = 0
            jobs[i].attempt = UUID()
            pump()
        default:
            break
        }
    }

    public func updateProgress(attempt: UUID, done: UInt64, total: UInt64) {
        // No state check: the final event may arrive just after the job finished.
        guard let i = jobs.firstIndex(where: { $0.attempt == attempt }) else { return }
        jobs[i].done = done
        jobs[i].total = total
        jobs[i].lastActivity = .now
    }

    public func startWatchdog(interval: Duration = .seconds(5)) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await self.checkForStalls(now: .now)
            }
        }
    }

    /// Restarts the service when a running job has made no progress for `stallTimeout`.
    public func checkForStalls(now: ContinuousClock.Instant = .now) async {
        let stalled = jobs.contains { $0.state == .running && now - $0.lastActivity > stallTimeout }
        guard stalled else { return }
        for i in jobs.indices where jobs[i].state == .running { jobs[i].lastActivity = now }
        await service.restart()
    }

    // MARK: Internals

    private func enqueue(_ kind: Kind, completion: Completion?) -> UUID {
        let job = Job(id: UUID(), kind: kind)
        jobs.append(job)
        if let completion { completions[job.id] = completion }
        pump()
        return job.id
    }

    private func index(_ id: UUID) -> Int? { jobs.firstIndex { $0.id == id } }

    private func pump() {
        var busy = Set(jobs.filter { $0.state == .running }.map(\.deviceID))
        for i in jobs.indices where jobs[i].state == .queued && !busy.contains(jobs[i].deviceID) {
            busy.insert(jobs[i].deviceID)
            jobs[i].state = .running
            jobs[i].lastActivity = .now
            let job = jobs[i]
            Task { await run(job) }
        }
    }

    private func run(_ job: Job) async {
        let result: Result<URL?, MTPError>
        do {
            switch job.kind {
            case .download(let entry, let deviceID, let directory):
                result = .success(try await service.download(jobID: job.attempt, entry: entry,
                                                             deviceID: deviceID, into: directory))
            case .upload(let url, let folder):
                _ = try await service.upload(jobID: job.attempt, fileURL: url, to: folder)
                result = .success(nil)
            }
        } catch {
            result = .failure(MTPError.from(error))
        }
        guard let i = index(job.id), jobs[i].attempt == job.attempt else { return }
        switch result {
        case .success(let url): finish(i, .finished(url))
        case .failure(.cancelled): finish(i, .cancelled)
        case .failure(let error): finish(i, .failed(error))
        }
        pump()
    }

    private func finish(_ i: Int, _ state: State) {
        jobs[i].state = state
        if case .finished = state { jobs[i].done = max(jobs[i].done, jobs[i].total) }
        let job = jobs[i]
        if let completion = completions.removeValue(forKey: job.id) {
            switch state {
            case .finished(let url): completion(.success(url))
            case .failed(let error): completion(.failure(error))
            default: completion(.failure(.cancelled))
            }
        }
        onJobFinished?(job)
    }
}
```

- [ ] **Step 4: Implement `AppModel.swift`**

```swift
import Foundation
import Observation
import MTPKit

@MainActor
@Observable
public final class AppModel {
    public let devices: DeviceStore
    public let transfers: TransferQueue
    @ObservationIgnored private let service: any MTPService

    public init(service: any MTPService) {
        self.service = service
        devices = DeviceStore(service: service)
        transfers = TransferQueue(service: service)
        transfers.onJobFinished = { [weak store = devices] job in
            guard case .upload(_, let folder) = job.kind, let store else { return }
            Task {
                await store.refresh(folder)
                await store.loadStorages(folder.deviceID)
            }
        }
    }

    public func start() async {
        await service.setEventHandler { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        await devices.reloadDevices()
        transfers.startWatchdog()
    }

    func handle(_ event: ServiceEvent) {
        switch event {
        case .devicesChanged(let list):
            devices.apply(list)
        case .progress(let attempt, let done, let total):
            transfers.updateProgress(attempt: attempt, done: done, total: total)
        case .interrupted:
            Task { await devices.reloadDevices() }
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path Packages/MTPKit`
Expected: the whole suite passes, including 8 `TransferQueueTests` and 3 `AppModelTests`.

- [ ] **Step 6: Commit**

```bash
git add -A Packages/MTPKit
git commit -m "feat(TetherCore): TransferQueue with per-device scheduling, watchdog and AppModel"
```

---

### Task 13: Minimal window: sidebar, file list, drag in/out, transfers

**Files:**
- Modify: `Tether/TetherApp.swift`
- Create: `Tether/ContentView.swift`, `Tether/SidebarView.swift`, `Tether/BrowserView.swift`, `Tether/FileTableView.swift`, `Tether/FilePromise.swift`, `Tether/TransfersPopover.swift`

**Interfaces:**
- Consumes:
  - `AppModel`, `DeviceStore`, `TransferQueue` (Tasks 11–12)
  - `XPCMTPService.helper()` (Task 9)
  - `LocalMTPService` + `FakeDeviceProvider.demo()` (Tasks 4, 8)
  - `Transfers.safeName` (Task 6)
- Produces: the runnable app. Launch argument `-UseFakeDevices YES` runs it without hardware.

UI-level automated tests come in Plan 2 (XCUITest). This task is verified by running the app.

- [ ] **Step 1: Replace `Tether/TetherApp.swift`**

```swift
import SwiftUI
import MTPKit
import TetherCore

@main
struct TetherApp: App {
    @State private var model = AppModel(service: TetherApp.makeService())

    var body: some Scene {
        Window("Tether", id: "main") {
            ContentView()
                .environment(model)
                .task { await model.start() }
                .frame(minWidth: 720, minHeight: 420)
        }
    }

    /// `-UseFakeDevices YES` swaps the XPC helper for in-memory demo phones.
    private static func makeService() -> any MTPService {
        if UserDefaults.standard.bool(forKey: "UseFakeDevices") {
            return LocalMTPService(provider: FakeDeviceProvider.demo())
        }
        return XPCMTPService.helper()
    }
}
```

- [ ] **Step 2: Write `Tether/ContentView.swift`**

```swift
import SwiftUI
import MTPKit
import TetherCore

struct StorageSelection: Hashable {
    let deviceID: DeviceID
    let storageID: UInt32
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: StorageSelection?
    @State private var path: [FileEntry] = []

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            if let selection {
                BrowserView(selection: selection, path: $path)
                    .id(selection)
            } else {
                ContentUnavailableView(
                    "No Phone Connected",
                    systemImage: "smartphone",
                    description: Text("Connect an Android phone with a USB cable, unlock it, and choose “File transfer” in the USB notification."))
            }
        }
        .onChange(of: selection) { path = [] }
        .onChange(of: model.devices.storages, initial: true) { ensureSelection() }
        .onChange(of: model.devices.devices) { ensureSelection() }
    }

    private func ensureSelection() {
        let available = model.devices.devices.flatMap { device in
            (model.devices.storages[device.id] ?? []).map { StorageSelection(deviceID: device.id, storageID: $0.id) }
        }
        if let selection, available.contains(selection) { return }
        selection = available.first
    }
}
```

- [ ] **Step 3: Write `Tether/SidebarView.swift`**

```swift
import SwiftUI
import MTPKit
import TetherCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: StorageSelection?

    var body: some View {
        List(selection: $selection) {
            Section("Devices") {
                ForEach(model.devices.devices) { device in
                    switch device.state {
                    case .ready:
                        Label(device.displayName, systemImage: "smartphone")
                            .font(.headline)
                        ForEach(model.devices.storages[device.id] ?? []) { storage in
                            StorageRow(storage: storage)
                                .tag(StorageSelection(deviceID: device.id, storageID: storage.id))
                        }
                    case .unavailable(let error):
                        VStack(alignment: .leading, spacing: 2) {
                            Label(device.displayName, systemImage: "smartphone")
                            Text(error.localizedDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 230)
    }
}

private struct StorageRow: View {
    let storage: StorageInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(storage.name, systemImage: "internaldrive")
            if storage.capacity > 0 {
                ProgressView(value: Double(storage.capacity - min(storage.freeSpace, storage.capacity)),
                             total: Double(storage.capacity))
                    .controlSize(.mini)
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(clamping: storage.freeSpace), countStyle: .file)) available")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 12)
    }
}
```

- [ ] **Step 4: Write `Tether/FilePromise.swift`**

```swift
import AppKit
import UniformTypeIdentifiers
import MTPKit
import TetherCore

/// Lets Finder pull a phone file: the download is queued when the user drops.
final class FilePromise: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private let entry: FileEntry
    private let deviceID: DeviceID
    private let queue: TransferQueue

    private init(entry: FileEntry, deviceID: DeviceID, queue: TransferQueue) {
        self.entry = entry
        self.deviceID = deviceID
        self.queue = queue
    }

    @MainActor
    static func provider(for entry: FileEntry, deviceID: DeviceID, queue: TransferQueue) -> NSFilePromiseProvider {
        let type: UTType = entry.isFolder
            ? .folder
            : UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
        let delegate = FilePromise(entry: entry, deviceID: deviceID, queue: queue)
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: delegate)
        provider.userInfo = delegate // the provider holds its delegate weakly
        return provider
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        Transfers.safeName(entry.name)
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        let directory = url.deletingLastPathComponent()
        let completion = Unchecked(completionHandler)
        let entry = entry, deviceID = deviceID, queue = queue
        Task { @MainActor in
            queue.enqueueDownload(entry, deviceID: deviceID, into: directory) { result in
                switch result {
                case .success: completion.value(nil)
                case .failure(let error): completion.value(error)
                }
            }
        }
    }
}
```

- [ ] **Step 5: Write `Tether/FileTableView.swift`**

```swift
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MTPKit

/// Finder-style list backed by NSTableView: sortable columns, multi-select,
/// drag-out via file promises, drop-in of Finder files.
struct FileTableView: NSViewRepresentable {
    var entries: [FileEntry]
    var onOpen: (FileEntry) -> Void
    var onDropFiles: ([URL]) -> Void
    var makePromise: (FileEntry) -> NSFilePromiseProvider

    enum Column: String, CaseIterable {
        case name, size, modified

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

        var title: String {
            switch self {
            case .name: String(localized: "Name")
            case .size: String(localized: "Size")
            case .modified: String(localized: "Date Modified")
            }
        }

        var width: CGFloat {
            switch self {
            case .name: 320
            case .size: 90
            case .modified: 170
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            table.addTableColumn(tableColumn)
        }
        table.sortDescriptors = [NSSortDescriptor(key: Column.name.rawValue, ascending: true)]
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openClicked(_:))
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.show(entries)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: FileTableView
        weak var table: NSTableView?
        private var source: [FileEntry] = []
        private var rows: [FileEntry] = []

        init(parent: FileTableView) { self.parent = parent }

        func show(_ entries: [FileEntry]) {
            guard entries != source else { return }
            source = entries
            resort()
        }

        private func resort() {
            let descriptor = table?.sortDescriptors.first
            let key = descriptor?.key ?? Column.name.rawValue
            let ascending = descriptor?.ascending ?? true
            func less(_ a: FileEntry, _ b: FileEntry) -> Bool {
                switch key {
                case Column.size.rawValue:
                    a.size != b.size ? a.size < b.size : a.name.localizedStandardCompare(b.name) == .orderedAscending
                case Column.modified.rawValue:
                    (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
                default:
                    a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            }
            rows = source.sorted { a, b in
                if a.isFolder != b.isFolder { return a.isFolder } // folders first, like Finder
                return ascending ? less(a, b) : less(b, a)
            }
            table?.reloadData()
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let entry = rows[row]
            let cell = (tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTableCellView)
                ?? makeCell(column)
            switch column {
            case .name:
                cell.textField?.stringValue = entry.name
                cell.imageView?.image = icon(for: entry)
            case .size:
                cell.textField?.stringValue = entry.isFolder
                    ? "—" : ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file)
            case .modified:
                cell.textField?.stringValue = entry.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—"
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            resort()
        }

        @objc func openClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard rows.indices.contains(row) else { return }
            parent.onOpen(rows[row])
        }

        // MARK: Drag out

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            parent.makePromise(rows[row])
        }

        // MARK: Drop in

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            if (info.draggingSource as? NSTableView) === tableView { return [] }
            guard info.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                        options: [.urlReadingFileURLsOnly: true]) else { return [] }
            tableView.setDropRow(-1, dropOperation: .on) // whole table = current folder
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                                 options: [.urlReadingFileURLsOnly: true]) as? [URL],
                  !urls.isEmpty else { return false }
            parent.onDropFiles(urls)
            return true
        }

        // MARK: Cells

        private func makeCell(_ column: Column) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = column.identifier
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            if column == .name {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                ])
            } else {
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
                if column == .size { text.alignment = .right }
            }
            NSLayoutConstraint.activate([
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func icon(for entry: FileEntry) -> NSImage {
            let type: UTType = entry.isFolder
                ? .folder
                : UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
            return NSWorkspace.shared.icon(for: type)
        }
    }
}
```

- [ ] **Step 6: Write `Tether/TransfersPopover.swift`**

```swift
import SwiftUI
import MTPKit
import TetherCore

struct TransfersButton: View {
    @Environment(AppModel.self) private var model
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Transfers", systemImage: model.transfers.hasActiveJobs ? "arrow.down.circle.dotted" : "arrow.down.circle")
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            TransfersList()
                .environment(model)
                .frame(width: 340)
                .frame(minHeight: 80, maxHeight: 400)
        }
    }
}

private struct TransfersList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.transfers.jobs.isEmpty {
            Text("No transfers")
                .foregroundStyle(.secondary)
                .padding()
        } else {
            List(model.transfers.jobs.reversed()) { job in
                TransferRow(job: job)
            }
        }
    }
}

private struct TransferRow: View {
    @Environment(AppModel.self) private var model
    let job: TransferQueue.Job

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.name).lineLimit(1).truncationMode(.middle)
                switch job.state {
                case .queued:
                    Text("Waiting…").font(.caption).foregroundStyle(.secondary)
                case .running:
                    ProgressView(value: job.fraction)
                case .finished:
                    Text("Done").font(.caption).foregroundStyle(.secondary)
                case .cancelled:
                    Text("Cancelled").font(.caption).foregroundStyle(.secondary)
                case .failed(let error):
                    Text(error.localizedDescription).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            switch job.state {
            case .queued, .running:
                Button("Cancel", systemImage: "xmark.circle.fill") { model.transfers.cancel(job.id) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            case .failed, .cancelled:
                Button("Retry", systemImage: "arrow.clockwise") { model.transfers.retry(job.id) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            case .finished(let url?):
                Button("Show in Finder", systemImage: "magnifyingglass") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
            case .finished(nil):
                EmptyView()
            }
        }
    }
}
```

- [ ] **Step 7: Write `Tether/BrowserView.swift`**

```swift
import SwiftUI
import MTPKit
import TetherCore

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    let selection: StorageSelection
    @Binding var path: [FileEntry]

    private var folder: FolderRef {
        FolderRef(deviceID: selection.deviceID, storageID: selection.storageID,
                  folderID: path.last?.objectID ?? FileEntry.rootID)
    }

    private var title: String {
        path.last?.name ?? model.devices.storage(for: folder)?.name ?? String(localized: "Phone")
    }

    var body: some View {
        let listing = model.devices.listings[folder]
        FileTableView(entries: listing?.entries ?? [],
                      onOpen: open,
                      onDropFiles: upload,
                      makePromise: { FilePromise.provider(for: $0, deviceID: selection.deviceID, queue: model.transfers) })
            .overlay { overlay(for: listing) }
            .navigationTitle(title)
            .navigationSubtitle(listing?.isUpdating == true ? String(localized: "Updating…") : "")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { path.removeLast() } label: { Label("Back", systemImage: "chevron.left") }
                        .disabled(path.isEmpty)
                        .keyboardShortcut(.upArrow, modifiers: .command)
                }
                ToolbarItem {
                    Button { Task { await model.devices.refresh(folder) } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r")
                }
                ToolbarItem {
                    Button(action: chooseFilesToUpload) { Label("Upload", systemImage: "square.and.arrow.up") }
                }
                ToolbarItem { TransfersButton() }
            }
            .task(id: folder) { await model.devices.refresh(folder) }
    }

    @ViewBuilder
    private func overlay(for listing: DeviceStore.Listing?) -> some View {
        if listing == nil || (listing!.isUpdating && listing!.entries.isEmpty) {
            ProgressView()
        } else if let error = listing?.error, listing?.entries.isEmpty == true {
            ContentUnavailableView {
                Label("Can’t Read This Folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.localizedDescription)
            } actions: {
                Button("Try Again") { Task { await model.devices.refresh(folder) } }
            }
        } else if listing?.entries.isEmpty == true {
            ContentUnavailableView("Empty Folder", systemImage: "folder",
                                   description: Text("Drop files here to copy them to the phone."))
                .allowsHitTesting(false)
        }
    }

    private func open(_ entry: FileEntry) {
        if entry.isFolder { path.append(entry) }
    }

    private func upload(_ urls: [URL]) {
        for url in urls { model.transfers.enqueueUpload(url, to: folder) }
    }

    private func chooseFilesToUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Upload")
        panel.begin { response in
            guard response == .OK else { return }
            upload(panel.urls)
        }
    }
}
```

- [ ] **Step 8: Build**

Run: `xcodegen generate && xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Debug -derivedDataPath DerivedData build 2>&1 | grep -E "error:|BUILD" | head -20`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 9: Verify with fake phones**

Run: `DerivedData/Build/Products/Debug/Tether.app/Contents/MacOS/Tether -UseFakeDevices YES`
Expected, checking each by hand:
- **Sidebar:** shows "Pixel 9" with "Internal shared storage" selected, plus "Galaxy S25" with the unlock message.
- **List:** shows `DCIM`, `Download`, `Music` (folders first), then `notes.txt`.
- **Navigation:** double-clicking `DCIM` → `Camera` shows 12 `IMG_….jpg` rows. ⌘↑ goes back.
- **Drag out:** dragging `IMG_0001.jpg` to the Desktop shows progress in the Transfers popover, and the file appears on the Desktop. Dragging it again creates `IMG_0001 2.jpg`.
- **Drop in:** dropping a Finder file into the list adds it to the folder after the upload finishes.
- **Cancel:** cancelling a running transfer in the popover shows "Cancelled" and leaves no `.partial` on the Desktop.

- [ ] **Step 10: Verify with a real phone**

1. Quit Image Capture and Photos. If the phone shows "Another app is using the phone", run `killall ptpcamerad` and wait 3 seconds. Plan 2 automates this.
2. Connect an Android phone, unlock it, and choose **File transfer** in the USB notification.
3. Run: `DerivedData/Build/Products/Debug/Tether.app/Contents/MacOS/Tether`

Expected:
- The phone appears within a few seconds, and its storage lists the real folders.
- Dragging a photo to the Desktop works.
- Dropping a file into `Download` works, and it appears on the phone in the Files app.
- Unplugging the cable makes the phone vanish from the sidebar. Any running transfer shows "The phone was disconnected." and can be retried after reconnecting.
- A locked phone shows the unlock message, then becomes ready within about 3 s of unlocking.

Record the phone model and Android version tested in the commit message.

- [ ] **Step 11: Commit**

```bash
git add Tether
git commit -m "feat(app): sidebar, file list with drag in/out, transfers popover

Verified with -UseFakeDevices and on <phone model>, Android <version>."
```

---

## Spec coverage (Plan 1)

| Spec section | Covered by |
|---|---|
| §2: platform (macOS 15, Swift 6, universal) | Tasks 1, 2 |
| §2: LGPL dynamic linking | Tasks 1, 2 (embed); acknowledgements → Plan 3 |
| §3: MTPKit | Tasks 3–9 |
| §3: MTPHelper (one thread per device) | Tasks 5, 10 |
| §3: DeviceStore, TransferQueue | Tasks 11, 12 |
| §4: browsing cache and "Updating…" | Tasks 11, 13 |
| §4: download (`.partial`, file promises) | Tasks 6, 13 |
| §4: upload (free space, recursion, conflict detection) | Task 7. The conflict **dialog** → Plan 2 |
| §4: delete, rename, new folder | Service + store: Tasks 8, 11. UI → Plan 2 |
| §6: unplug, crash, hang watchdog, free space | Tasks 7, 8, 9, 11, 12 |
| §7: FakeDevice unit tests | Tasks 3–12 |
| §5: full UI, §4 Quick Look/thumbnails, §6 diagnostics, localization | Plan 2 |
| §7: CI, §2 Sparkle/notarization, device checklist | Plan 3 |
