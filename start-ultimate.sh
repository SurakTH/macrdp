#!/bin/bash
# Ultimate high-clarity & ultra-smooth 60 FPS launcher for macrdp

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/scripts/ensure-release.sh"
ensure_macrdp_release "$DIR"

# Disable blank recovery drop loop (prevents mstsc reconnect loop)
export MACRDP_BLANK_RECOVERY=0

# Run macrdp with tuned high-clarity & low-latency flags:
# - 60 FPS + Low buffer + Flush frames for instant mouse/keyboard response
# - 25 Mbps high-fidelity bitrate ceiling + Adaptive Bitrate for pin-sharp text
# - On-change Keyframe generation for instant pristine redraws without motion blur
# - 2.0s Keyframe interval + UDP multitransport + AAC audio
# - Unminimize on switch + Windows ergonomics
exec "$DIR/target/release/macrdp" \
  --bind 0.0.0.0:3390 \
  --enable-h264 \
  --fps 60 \
  --bitrate 25 \
  --adaptive-bitrate \
  --keyframe-on-change \
  --keyframe-change-pct 15 \
  --keyframe-click-pct 3 \
  --keyframe-interval 2.0 \
  --enable-udp-multitransport \
  --enable-aac \
  --h264-frames-in-flight 1 \
  --flush-frames 2 \
  --unminimize-on-switch \
  --map-ctrl-to-cmd \
  --alt-tab-switch "$@"
