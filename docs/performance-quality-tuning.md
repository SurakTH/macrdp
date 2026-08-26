# Performance and Quality Tuning Record

This document records the performance, image-quality, stability, launcher, and
verification work applied on 2026-08-26. It is the consolidated change record;
the user-facing choices are `./start.sh` (Ultimate), `./start.sh lan` (LAN Max),
and `./start.sh native` (Native bitmap). AVC444 is retained for diagnostics but
is not a recommended user-facing mode.

## Result at a glance

| Area | What changed | Intended result | Trade-off |
|---|---|---|---|
| H.264 capture | Retain the last CoreVideo surface for flush frames instead of copying a full BGRA frame | Less memory traffic and allocation pressure | Holds one SCK surface only for the bounded flush burst |
| H.264 packetization | Reuse the ship batch and rewrite AVCC P-frames to Annex-B in place | Fewer frame-sized allocations and copies | Keyframes still allocate when SPS/PPS must be prepended |
| VideoToolbox input | Use the session pixel-buffer pool when available, with a direct-allocation fallback | Stable VT-compatible buffers and allocator reuse | Pooling alone is not claimed to improve encode throughput |
| AVC444 | One continuous H.264 stream, synchronized all-IDR main/auxiliary pairs, 2x2 chroma averaging, timestamp pairing, NAL sanitation, macroblock padding, reusable YUV buffers | 4:4:4 color around text/UI without a fragile temporal reference chain | Roughly twice the encode work and much higher all-intra bandwidth; preset is capped at 10 FPS |
| Native capture | HiDPI 1:1 capture, 12 FPS, latest-frame-only queue | Sharp text without a stale-frame backlog | Deliberately less fluid than 60 FPS H.264 |
| RemoteFX | Maximum-quality quantization for every wavelet band | Cleaner text and one-pixel UI edges | Larger encoded updates |
| NSCodec | CLL=1, no chroma subsampling, no dynamic fidelity | Highest NSCodec fidelity allowed by the protocol | Larger encoded updates |
| Bitmap stability | Pause while minimized and force a full repaint on resume | Avoid queued repaint work and stale restored surfaces | First restored update is a full repaint |
| Launchers | Automatic optimized build/sign and named modes | One-command startup with no manual rebuild step | First launch after source changes waits for the release build |

## H.264 / EGFX changes

### CoreVideo and VideoToolbox input

- The VideoToolbox session is created with explicit BGRA pixel-buffer source
  attributes so it can expose a compatible `CVPixelBufferPool`.
- Encoding requests a buffer from that pool and falls back to direct
  `CVPixelBufferCreate` if the pool is unavailable.
- BGRA source and destination stride are validated before copying. Pixel-buffer
  lock/unlock status, null planes/base addresses, and partially-created session
  cleanup are checked rather than silently continuing with invalid state.
- This pool is retained for compatibility and allocation reuse. Earlier local
  A/B measurements found pool allocation alone approximately throughput-neutral;
  the expensive part remains filling/converting the pixels, so no standalone
  speed claim is made for the pool.

### Frame ownership and wire conversion

- `EncodedFrame` is move-only rather than cloned through the shipping path.
- The vector used to batch frames for shipping is retained and reused.
- Frames are drained/consumed after submission, and stale leftovers are cleared
  when a pre-drain error occurs.
- AVCC P-frames are rewritten to Annex-B in place because the four-byte AVCC
  length prefix and the required four-byte start code occupy the same space.
- Keyframes allocate only when the Annex-B SPS/PPS parameter sets must be
  prepended.
- A unit test guards the P-frame allocation reuse by checking that the backing
  pointer is unchanged.

### Trailing flush frames

- The capture loop retains the owned ScreenCaptureKit `CVPixelBuffer` for the
  short H.264 flush burst instead of copying the entire BGRA desktop into a
  `Vec<u8>`.
- The retained surface is released after the final flush, before a live resize,
  and while display output is suppressed.
- At 3840×2160×4 bytes×60 FPS, avoiding a full-frame copy removes a theoretical
  memory-copy rate of about 1.99 GB/s during continuous motion. This is a
  calculated upper bound, not an end-to-end benchmark result.

### Ultimate preset

`start-ultimate.sh` remains the best overall quality/motion/latency preset. It
uses H.264 at 60 FPS, a 25 Mbps ceiling, adaptive bitrate, one frame in flight,
two trailing flush frames, on-change keyframes, a 2-second periodic keyframe,
UDP multitransport, and AAC audio.

### LAN Max preset

`start-lan.sh` keeps the proven AVC420 path and spends a clean LAN's bandwidth
on quality: HiDPI capture, 60 FPS, a fixed 50 Mbps VideoToolbox target, one
frame in flight, two trailing flush frames, on-change plus two-second recovery
IDRs, and the stable TCP EGFX path. Audio remains uncompressed PCM;
its roughly 1.5 Mbps cost is negligible on a LAN and avoids AAC encoder/priming
latency. Adaptive bitrate is intentionally off so a short transient cannot
silently lower image quality.

TCP is the default because it is the live-verified compatibility path. Set
`MACRDP_LAN_TRANSPORT=udp ./start.sh lan` to explicitly try EGFX migration onto
reliable RDPEUDP; clients without multitransport support remain on TCP.
`MACRDP_LAN_BITRATE` and `MACRDP_LAN_FPS` override the 50 Mbps and 60 FPS
defaults. On mstsc build 26100, 80 Mbps caused an immediate client reset on the
first AVC420 frame over both TCP and UDP, while the existing 50 Mbps Fast preset
rendered normally. Treat values above 50 Mbps as client-specific experiments.
More than 60 FPS is not useful for a normal 60 Hz RDP client and only raises
encode/decode load.

### AVC444 sharp + smooth preset

`start-avc444.sh` enables `--enable-h264 --avc444 --hidpi` at 10 FPS with a
combined 60 Mbps adaptive ceiling, one logical frame in flight, two trailing
flush frames, and AAC. TCP is the default transport for this preset because a
logical frame contains two ordered H.264 payloads; UDP remains an explicit
option. As in the Ultimate launcher, experimental blank recovery defaults off
to avoid a reconnect loop on clients whose QoE reporting is unreliable; set
`MACRDP_BLANK_RECOVERY=1` explicitly to restore it. `MACRDP_AVC444_FPS` and
`MACRDP_AVC444_BITRATE` override the defaults. The launcher also defaults
`MACRDP_AVC444_ALL_INTRA=1`; set it to `0` only to test the experimental
inter-frame path. The encoder itself makes the same stability choice when
`--avc444` is run directly without the launcher.

The implementation converts BGRA to full-resolution BT.709 YUV444 using
vImage, pads both encoder dimensions to 16 pixels, performs the AVC444 v1
B-area split, then submits main and auxiliary views consecutively to one
VideoToolbox session. This single continuous H.264 reference chain is required
by MS-RDPEGFX; the initial two-session implementation produced severe color
corruption after inter frames began. Persistent conversion/split buffers avoid
frame-sized allocations. Main U/V uses the 2x2 chroma average used by FreeRDP's
production packing path. Outputs are paired by adjacent even/odd PTS; a mismatch
is dropped and arms synchronized main+auxiliary IDRs. The AVC444 wire path keeps
only SPS/PPS and coded-slice NAL units so optional VideoToolbox metadata cannot
perturb the client's one shared decoder. A vendored `ironrdp-egfx` correction
also writes exclusive `width`/`height` AVC region bounds while leaving the outer
destination unchanged; the pinned helper's `width-1`/`height-1` metadata made a
1920x1080 AVC444 region an odd 1919x1079.
Positive V10+ AVC capability enables AVC444. V8.1 AVC420 automatically uses the
existing single-stream path, and no-AVC clients keep the bitmap fallback.

The 10 FPS default is intentional: every logical frame contains two IDR
pictures, so this mode optimizes for decoder recovery and visual integrity over
motion. The single-session, all-IDR, and exclusive-region revisions were all
live-tested on mstsc build 26100 and still produced the same severe gray/color-
stripe corruption. AVC444 remains a diagnostic mode, not a usable preset.

## Native bitmap changes

### What “Native” means

Native is the Windows-like RemoteFX/QOI dirty-region/tile path, not H.264. The
server and client negotiate the actual codec:

- Windows `mstsc` normally chooses RemoteFX.
- FreeRDP commonly chooses QOIZ or QOI.
- Some Windows App versions choose NSCodec.
- With no mutually-supported surface codec, the connection falls back to
  bitmap/RLE.

QOI and QOIZ are lossless. RemoteFX and NSCodec are not mathematically lossless,
but are configured here for their highest supported fidelity.

### Native launcher preset

`start-native.sh` now passes `--hidpi --fps 12`:

- `--hidpi` captures the physical display at its backing-pixel resolution and
  pins the session to a real 1:1 size. This keeps ScreenCaptureKit dirty
  rectangles valid. Previously, accepting an unrelated client resolution could
  force full-frame bitmap updates on every tick.
- 12 FPS is intentional. Bitmap codecs spend more CPU and bandwidth per large
  update than H.264, so the lower cap prioritizes clarity and bounded load.
- `MACRDP_NATIVE_FPS=15 ./start.sh native` is available for a fast LAN/client,
  but 12 FPS is the stability-oriented default.

### Latest-frame behavior

The asynchronous ScreenCaptureKit queue capacity is one for the bitmap path.
When encoding or socket output is slower than capture, the queue discards the
old sample and retains the newest sample. The client therefore sees fewer
intermediate motion frames rather than replaying stale screen states and
accumulating input-visible lag. H.264 retains its deeper queue because it has a
separately bounded hardware pipeline.

### Maximum-fidelity codecs

- RemoteFX uses quantizer value 6 for all ten wavelet bands. Six is the
  highest-fidelity value permitted by MS-RDPRFX; the standard 6–9 profile saves
  bandwidth by reducing high-frequency detail, which can soften small text.
- NSCodec advertises color-loss level 1, disables chroma subsampling, and
  disables dynamic fidelity. Negotiation now chooses the lower of the server
  and client maximum CLL values, ensuring the server's CLL=1 request is honored
  while remaining valid for both peers.
- QOI/QOIZ remain lossless and require no quality reduction.

### Encoder allocation and retry stability

- RemoteFX retains and reuses its per-tile transform workspace instead of
  allocating and zero-initializing it for every dirty rectangle.
- The serialized RemoteFX output workspace is also retained and reused.
- If the output-size estimate is too small, the one-shot RemoteFX desktop header
  is now preserved across the retry. Previously it was consumed on the first
  attempt, so a larger retry could omit the required initial header.

### Minimize and restore

The `SuppressOutput` gate now covers bitmap sessions after their initial seed,
not only EGFX sessions. A genuinely minimized client stops capture and encoding
after the debounce period. On restore, the bitmap seed is invalidated and the
next sample repaints the complete surface before dirty-region updates resume.

## Launcher and build workflow

- `./start.sh` is a dispatcher. No mode means Ultimate; `avc444` selects the
  diagnostic-only 4:4:4 preset, `lan` selects LAN Max, `native` selects the
  high-clarity bitmap preset, and `fast` selects low-latency H.264.
- Every preset sources `scripts/ensure-release.sh`.
- The helper builds `target/release/macrdp` when the binary is missing or older
  than Rust/native source, Cargo metadata, or the toolchain file.
- After a build, the binary receives an ad-hoc signature to keep the normal
  macOS development/TCC behavior consistent.
- `MACRDP_SKIP_AUTO_BUILD=1` skips the automatic check, but cannot start if the
  release binary is missing.
- The current project release binary was rebuilt and ad-hoc signed after these
  source changes.

## Code-quality cleanup

- The authentication guard constructor was renamed to describe what it accepts
  (`from_allow_ips`).
- Slice conversion code uses exact fixed-size chunk APIs where appropriate.
- Formatting and strict Clippy checks pass with warnings treated as errors.

## Verification status

- Optimized release build: passed.
- Ad-hoc signature verification: passed.
- Launcher parsing: `./start.sh native --help` reaches the release binary with
  `--hidpi --fps 12`; `./start.sh avc444 --help` reaches it with
  `--enable-h264 --avc444 --hidpi --fps 10 --bitrate 60`, with
  `MACRDP_AVC444_ALL_INTRA=1` by default.
- Strict lint: `cargo clippy --all-targets -- -D warnings` passed.
- Runnable automated tests: 209 passed; 4 tests remain ignored (three benchmarks
  plus one VideoToolbox AVC444 hardware integration test).
- Four environment-dependent tests cannot run in this test process because they
  require AudioToolbox encoding, AppKit Pasteboard access, or an available
  hardware VideoToolbox encoder. A full run confirmed those exact environmental
  failures; the remaining suite passes.

These checks validate compilation, protocol logic, and the testable performance
paths. They do not replace an end-to-end visual/latency check from the user's
actual RDP client and network. AVC444 has been visually tested and remains
corrupted on the target mstsc build, so do not use it for normal sessions.
Native remains the sharpest/most-conservative mode; Ultimate is the best
overall choice, while LAN is the highest-quality practical AVC420 preset for a
clean local network.

## Commands to use

```bash
# Best overall balance
./start.sh

# Maximum practical AVC420 quality on a clean LAN
./start.sh lan

# Sharpest text/UI, fewer frames, stability-oriented
./start.sh native

# Optional Native increase for a fast client and LAN
MACRDP_NATIVE_FPS=15 ./start.sh native

# Optional LAN experiment: migrate EGFX video to reliable UDP
MACRDP_LAN_TRANSPORT=udp ./start.sh lan
```
