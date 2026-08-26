#!/bin/bash
# Diagnostics-only AVC444 launcher for macrdp.
# Full HiDPI pixels and 4:4:4 chroma keep colored text/UI edges crisp. Both
# pictures are IDRs by default, deliberately trading frame rate/bandwidth for
# decoder stability and removing AVC444's fragile temporal reference chain.
# The target mstsc build still renders corrupted colors; use Ultimate/LAN for
# normal sessions.

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/scripts/ensure-release.sh"
ensure_macrdp_release "$DIR"

AVC444_FPS="${MACRDP_AVC444_FPS:-10}"
AVC444_BITRATE="${MACRDP_AVC444_BITRATE:-60}"
# Stability is the point of this preset. Set MACRDP_AVC444_ALL_INTRA=0 only
# when deliberately testing the higher-FPS inter-frame path.
export MACRDP_AVC444_ALL_INTRA="${MACRDP_AVC444_ALL_INTRA:-1}"
# Match the proven Ultimate launcher: avoid an experimental recovery action
# turning a healthy-but-misreported mstsc session into a reconnect loop.
export MACRDP_BLANK_RECOVERY="${MACRDP_BLANK_RECOVERY:-0}"

echo "WARNING: AVC444 is diagnostics-only; tested mstsc clients still show severe color corruption." >&2

# TCP is intentional in this quality-first preset: each logical AVC444 frame
# carries two large H.264 pictures, and reliable in-order delivery is the most
# stable default. Users can still append --enable-udp-multitransport explicitly.
exec "$DIR/target/release/macrdp" \
  --bind 0.0.0.0:3390 \
  --enable-h264 \
  --avc444 \
  --hidpi \
  --fps "$AVC444_FPS" \
  --bitrate "$AVC444_BITRATE" \
  --adaptive-bitrate \
  --keyframe-interval 2.0 \
  --h264-frames-in-flight 1 \
  --flush-frames 2 \
  --enable-aac \
  --unminimize-on-switch \
  --map-ctrl-to-cmd \
  --alt-tab-switch "$@"
