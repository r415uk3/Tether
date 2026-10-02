#!/bin/bash
# Tests scripts/appcast.sh against a dummy DMG in a temp dir.
set -euo pipefail
cd "$(dirname "$0")/.."
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
head -c 4096 /dev/zero > "$T/x.dmg"
F="$T/appcast.xml"
fail() { echo "FAIL: $*" >&2; exit 1; }
scripts/appcast.sh "$T/x.dmg" 1.0.0 5 https://example.com/a.dmg SIG5 "$F" >/dev/null
scripts/appcast.sh "$T/x.dmg" 1.0.1 6 https://example.com/b.dmg SIG6 "$F" >/dev/null
[ "$(grep -c '<item>' "$F")" = 2 ] || fail "expected 2 items"
[ "$(sed -n 's:.*<sparkle\:version>\([0-9]*\)</sparkle\:version>.*:\1:p' "$F" | tr '\n' ' ')" = "6 5 " ] || fail "newest not first"
grep -q 'length="4096"' "$F" || fail "length missing"
if scripts/appcast.sh "$T/x.dmg" 1.0.1 6 https://example.com/b.dmg SIG6 "$F" 2>/dev/null; then fail "re-adding 6 succeeded"; fi
if scripts/appcast.sh "$T/x.dmg" 0.9.0 4 https://example.com/c.dmg SIG4 "$F" 2>/dev/null; then fail "adding 4 succeeded"; fi
if scripts/appcast.sh "$T/x.dmg" 1.0.2 7 https://example.com/d.dmg "" "$F" 2>/dev/null; then fail "empty sig succeeded"; fi
[ "$(grep -c '<item>' "$F")" = 2 ] || fail "feed changed by failed adds"
xmllint --noout "$F" || fail "xmllint"
echo "PASS: appcast tests"
