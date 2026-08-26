#!/bin/bash
# Generate an AppIcon.icns from a square (ideally 1024×1024) PNG.
# Usage: make-icns.sh <source.png> <out.icns>
set -euo pipefail

SRC="${1:?usage: make-icns.sh <source.png> <out.icns>}"
OUT="${2:?usage: make-icns.sh <source.png> <out.icns>}"
[ -f "$SRC" ] || { echo "no such icon source: $SRC" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Render and package the standard 16–1024 px representations directly. This
# avoids an iconutil regression seen on macOS 15 where even a valid RGBA
# iconset can be rejected as "Invalid Iconset".
BUILDER="$WORK/make-icns"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
xcrun swiftc "$SCRIPT_DIR/make-icns.swift" -o "$BUILDER"
"$BUILDER" "$SRC" "$OUT"
echo "wrote $OUT"
