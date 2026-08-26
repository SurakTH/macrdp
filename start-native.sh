#!/bin/bash
# Native high-clarity bitmap launcher for macrdp (Windows / GNOME style)
# - Captures the physical panel at its 1:1 backing-pixel resolution (HiDPI)
# - Sends only changed regions, with no H.264 chroma blur around text
# - Uses a deliberately low frame cap so large bitmap updates cannot outrun the client

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/scripts/ensure-release.sh"
ensure_macrdp_release "$DIR"

# Twelve frames per second is intentional: this preset prioritizes stable,
# pin-sharp office/text rendering over motion. Override only when the link and
# client are known to keep up, for example MACRDP_NATIVE_FPS=15.
NATIVE_FPS="${MACRDP_NATIVE_FPS:-12}"

# Run macrdp in native RemoteFX / QOI / NSCodec bitmap mode. --hidpi also pins
# capture to a real 1:1 display size, preserving ScreenCaptureKit dirty rects;
# accepting an arbitrary client size here would force expensive full-frame
# updates whenever its dimensions differ from the Mac panel.
exec "$DIR/target/release/macrdp" \
  --bind 0.0.0.0:3390 \
  --hidpi \
  --fps "$NATIVE_FPS" \
  --map-ctrl-to-cmd \
  --alt-tab-switch \
  --unminimize-on-switch "$@"
