#!/bin/bash
# Simple launcher: recommended H.264 mode by default, with named alternatives.

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

case "${1:-ultimate}" in
  ultimate|quality|balanced)
    [[ $# -gt 0 ]] && shift
    exec "$DIR/start-ultimate.sh" "$@"
    ;;
  lan|max|lan-max)
    shift
    exec "$DIR/start-lan.sh" "$@"
    ;;
  native|sharp)
    shift
    exec "$DIR/start-native.sh" "$@"
    ;;
  avc444|sharp-smooth|windows)
    shift
    exec "$DIR/start-avc444.sh" "$@"
    ;;
  fast|latency)
    shift
    exec "$DIR/start-fast.sh" "$@"
    ;;
  -h|--help|help)
    cat <<'EOF'
Usage: ./start.sh [mode] [macrdp options]

Modes:
  ultimate  Recommended: best balance of quality, smoothness, and latency
  lan       LAN Max: HiDPI AVC420, 60 FPS, 50 Mbps, stable TCP, PCM audio
  native    HiDPI bitmap mode: sharpest text/UI, stable 12 FPS
  fast      Lowest-latency H.264 preset for a fast LAN
  avc444    Experimental diagnostics only; known color corruption on tested clients

The launcher automatically runs an optimized release build when source files
are newer than the binary. Set MACRDP_SKIP_AUTO_BUILD=1 to disable that check.
EOF
    ;;
  *)
    # Backward-compatible: an option such as --allow-ip means ultimate mode.
    exec "$DIR/start-ultimate.sh" "$@"
    ;;
esac
