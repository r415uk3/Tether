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
