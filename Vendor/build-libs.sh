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
