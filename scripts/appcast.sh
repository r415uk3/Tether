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
  cat > "$FEED" <<FEEDEOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Tether</title>
    <link>https://r415uk3.github.io/Tether/appcast.xml</link>
    <language>en</language>
  </channel>
</rss>
FEEDEOF
fi
grep -q "<sparkle:version>$BUILD</sparkle:version>" "$FEED" && { echo "build $BUILD already in feed" >&2; exit 1; }
LAST=$(sed -n 's:.*<sparkle\:version>\([0-9]*\)</sparkle\:version>.*:\1:p' "$FEED" | sort -n | tail -1)
[ -z "$LAST" ] || [ "$BUILD" -gt "$LAST" ] || { echo "build $BUILD not greater than $LAST" >&2; exit 1; }
# Insert the item right after <language>…</language>.
ITEM="$ITEM" perl -0pi -e 's#(</language>\n)#$1$ENV{ITEM}\n#' "$FEED"
xmllint --noout "$FEED"
echo "appcast: added $VERSION ($BUILD), $LEN bytes"
