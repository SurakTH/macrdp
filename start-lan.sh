#!/bin/bash
# LAN Max: highest live-verified AVC420 quality at 60 FPS on a clean LAN.
# AVC444 is deliberately not used; this stays on the proven VideoToolbox/EGFX
# AVC420 path and spends LAN bandwidth to reduce compression artifacts.

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/scripts/ensure-release.sh"
ensure_macrdp_release "$DIR"

LAN_FPS="${MACRDP_LAN_FPS:-60}"
LAN_BITRATE="${MACRDP_LAN_BITRATE:-50}"
LAN_TRANSPORT="${MACRDP_LAN_TRANSPORT:-tcp}"

ARGS=(
  --bind 0.0.0.0:3390
  --enable-h264
  --hidpi
  --fps "$LAN_FPS"
  --bitrate "$LAN_BITRATE"
  --keyframe-on-change
  --keyframe-change-pct 15
  --keyframe-click-pct 3
  --keyframe-interval 2.0
  --h264-frames-in-flight 1
  --flush-frames 2
)

# Keep the proven reconnect behavior. The QoE-based blank detector is useful
# on difficult links but can misread some healthy clients; LAN Max favors an
# uninterrupted session.
export MACRDP_BLANK_RECOVERY="${MACRDP_BLANK_RECOVERY:-0}"

case "$LAN_TRANSPORT" in
  udp)
    # Explicit clean-LAN experiment. A client without multitransport support
    # remains on TCP, but EGFX migration is not the compatibility default.
    ARGS+=(--enable-udp-multitransport --udp-migrate-egfx)
    ;;
  tcp)
    # Live-verified compatibility path. Video, input, audio, and clipboard all
    # use the ordinary RDP connection.
    ;;
  *)
    echo "MACRDP_LAN_TRANSPORT must be 'udp' or 'tcp'" >&2
    exit 2
    ;;
esac

echo "LAN Max: AVC420 ${LAN_FPS} FPS, ${LAN_BITRATE} Mbps, ${LAN_TRANSPORT}, PCM audio"

# PCM is intentional: its ~1.5 Mbps cost is negligible on a LAN and avoids AAC
# encode/priming latency. Fixed bitrate is also intentional. 50 Mbps is the
# highest value live-verified on mstsc build 26100; 80 Mbps made that client
# reset as soon as the first AVC420 frame arrived, over both TCP and UDP.
ARGS+=(--unminimize-on-switch --map-ctrl-to-cmd --alt-tab-switch)
exec "$DIR/target/release/macrdp" "${ARGS[@]}" "$@"
