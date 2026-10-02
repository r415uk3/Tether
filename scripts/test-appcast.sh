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
# Feed without <language>, and a CRLF feed: must insert correctly (or fail loudly).
for variant in nolang crlf; do
  G="$T/$variant.xml"
  printf '<?xml version="1.0" encoding="utf-8"?>\r\n<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\r\n  <channel>\r\n    <title>Tether</title>\r\n' > "$G"
  [ "$variant" = crlf ] && printf '    <language>en</language>\r\n' >> "$G"
  printf '  </channel>\r\n</rss>\r\n' >> "$G"
  [ "$variant" = nolang ] && perl -pi -e 's/\r$//' "$G"
  scripts/appcast.sh "$T/x.dmg" 1.0.0 5 https://example.com/a.dmg SIG5 "$G" >/dev/null || fail "$variant: first add failed"
  scripts/appcast.sh "$T/x.dmg" 1.0.1 6 https://example.com/b.dmg SIG6 "$G" >/dev/null || fail "$variant: second add failed"
  [ "$(sed -n 's:.*<sparkle\:version>\([0-9]*\)</sparkle\:version>.*:\1:p' "$G" | tr '\n' ' ')" = "6 5 " ] || fail "$variant: order"
  xmllint --noout "$G" || fail "$variant: xmllint"
done
# Feed with no </channel> must fail, not silently succeed.
printf '<rss/>\n' > "$T/bad.xml"
if scripts/appcast.sh "$T/x.dmg" 1.0.0 5 https://example.com/a.dmg SIG5 "$T/bad.xml" 2>/dev/null; then fail "malformed feed succeeded"; fi
echo "PASS: appcast tests"
