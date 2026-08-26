#!/bin/bash
# Ultra-low latency script for macrdp (60 FPS, 50 Mbps ceiling, low buffer)

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/scripts/ensure-release.sh"
ensure_macrdp_release "$DIR"

# Disable blank recovery drop loop (prevents mstsc reconnect loop)
export MACRDP_BLANK_RECOVERY=0

# Run macrdp with ultra-low latency flags (60 FPS reduces mstsc input delay)
exec "$DIR/target/release/macrdp" \
  --bind 0.0.0.0:3390 \
  --enable-h264 \
  --fps 60 \
  --bitrate 50 \
  --h264-frames-in-flight 1 \
  --map-ctrl-to-cmd \
  --alt-tab-switch \
  --enable-udp-multitransport "$@"
