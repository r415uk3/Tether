#!/bin/bash
# Extracts localizable strings from the app and package sources and merges them into the String Catalogs.
# xcodebuild doesn't update catalogs itself; run this after adding or changing user-facing strings.
set -euo pipefail
cd "$(dirname "$0")/.."
DD="$PWD/DerivedData/strings"
mkdir -p "$DD"
LOG="$DD/build.log"
{ xcodegen generate &&
  xcodebuild -project Tether.xcodeproj -scheme Tether -configuration Debug -derivedDataPath "$DD" \
      SWIFT_EMIT_LOC_STRINGS=YES ONLY_ACTIVE_ARCH=YES build; } >"$LOG" 2>&1 \
    || { echo "build failed; last 30 lines of $LOG:" >&2; tail -30 "$LOG" >&2; exit 1; }

sync() { # sync <catalog> <path fragment of the target's build dir>
    local catalog="$1" fragment="$2" args=()
    while IFS= read -r file; do args+=(--stringsdata "$file"); done < <(
        find "$DD/Build/Intermediates.noindex" -name '*.stringsdata' -path "*$fragment/Objects-normal/*" \
            ! -name 'Extracted*' | sort)
    [ ${#args[@]} -gt 0 ] || { echo "no stringsdata for $fragment" >&2; exit 1; }
    local out
    out=$(xcrun xcstringstool sync "$catalog" "${args[@]}" 2>&1) || { echo "$out" >&2; echo "sync failed for $catalog" >&2; exit 1; }
    # xcstringstool only warns (exit 0) when it can't read the catalog; treat that as a failure too.
    if grep -q "Skipping sync" <<<"$out"; then echo "$out" >&2; echo "sync failed for $catalog" >&2; exit 1; fi
    grep -v "skip staleness checking" <<<"$out" | grep . || true
    echo "synced $catalog"
}

sync Tether/Localizable.xcstrings "/Tether.build/Debug/Tether.build"
sync Packages/MTPKit/Sources/MTPKit/Resources/Localizable.xcstrings "/MTPKit-t.build"
sync Packages/MTPKit/Sources/TetherCore/Resources/Localizable.xcstrings "/TetherCore-t.build"
