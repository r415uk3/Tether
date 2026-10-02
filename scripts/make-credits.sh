#!/bin/bash
# Regenerates Tether/Resources/Credits.rtf from scripts/credits/*.txt.
# sparkle-license.txt is LICENSE from the resolved Sparkle package.
# lgpl-2.1.txt is COPYING from the libmtp tarball (tar -xOf Vendor/.cache/libmtp-*.tar.gz libmtp-*/COPYING).
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# lgpl-2.1.txt is ISO-8859-1 (verbatim from the tarball); convert so textutil gets UTF-8.
{ cat scripts/credits/credits.txt; iconv -f ISO-8859-1 -t UTF-8 scripts/credits/lgpl-2.1.txt; cat scripts/credits/sparkle-header.txt scripts/credits/sparkle-license.txt; } > "$tmp/Credits.txt"
mkdir -p Tether/Resources
textutil -convert rtf -encoding UTF-8 -font Helvetica -fontsize 11 "$tmp/Credits.txt" -output Tether/Resources/Credits.rtf
