# Audio: RDPSND, AAC, mute-on-minimize, and the microphone

How system audio reaches the client, the opt-in AAC compression path, and the
minimize/refocus behavior.

System audio rides over the RDPSND virtual channel as 16-bit stereo PCM at **44.1 kHz**. ScreenCaptureKit only supports 8 / 16 / 24 / 48 kHz, so the capture loop captures at 48 kHz and resamples to 44.1 with [`rubato`](https://github.com/HEnquist/rubato) before sending. The 44.1 kHz output is empirically load-bearing — the earlier 48 kHz feed over-fed mstsc into multi-second backlogs, and 44.1 fixed it (the precise mechanism is a pacing/rate-accounting effect; Windows resamples shared-mode streams to the endpoint mix format either way). A generation counter on the audio factory keeps a client reconnect from leaving a second capture loop feeding the channel. The vendored `ironrdp-server` carries a single patch that makes `dispatch_server_events` keep the *newest* queued waves on per-batch overflow instead of the oldest — without it, a one-off video-encode stall would bake a permanent audio-latency offset into the session.

The capture loop also **self-heals a dead SCK audio stream**: over a long session ScreenCaptureKit can stop delivering samples or transiently fail to start, which previously left the connection silent for the rest of the session (video is a separate stream and kept running). The loop now rebuilds the audio `SCStream` with capped exponential backoff (250 ms → 5 s) on both start failures and mid-stream end, resetting the backoff once a sample arrives; the generation guard still retires it on reconnect, so there's no double-capture.

**AAC compression** (opt-in, `--enable-aac`). By default audio is uncompressed PCM (~1.4 Mbit/s). Pass `--enable-aac` to encode it as **AAC-LC** over RDPSND (`WAVE_FORMAT_AAC_MS`, ~128 kbps by default — about 11x smaller), which matters over WAN or constrained links. The encoder is AudioToolbox (software AAC-LC); the wire payload is raw AAC access units. The server advertises AAC ahead of PCM, so clients that decode it (mstsc, Microsoft Remote Desktop / Windows App, FreeRDP built with AAC support) negotiate AAC automatically while clients without it fall back to PCM transparently. It's off by default because AAC adds ~40–50 ms of encoder priming latency — on a LAN, PCM's zero added latency is the better default. Tune the bitrate with `--aac-bitrate` (default `128000`; `96000` saves the most bandwidth, `192000` is near-transparent for music).

**Mute on minimize** (default-on, opt out with `--no-mute-on-minimize`). When the client minimizes its window it sends the standard `SuppressOutput { None }` PDU; the server stops emitting both EGFX video frames and RDPSND waves until the client refocuses (`RefreshRectangle` / `SuppressOutput { Some(rect) }`). Without this, mstsc accumulates a backlog of video frames + audio waves during a long minimize that has to chew through on refocus, producing several seconds of input lockout, audio drift, and a video catch-up storm. With it, you get a brief audio gap on refocus and audio + video resume in sync. Both gates are debounced (1 s) so transient `SuppressOutput` flaps mstsc emits under wire pressure (e.g., during a heavy local `cargo build`) don't oscillate the mute and cause stutter. Pass `--no-mute-on-minimize` if you specifically want audio to keep playing while the client window is minimized — accepting that audio will drift by however long was spent minimized.

**PCM queue during video stalls.** PCM is sent in 10 ms waves as soon as the
writer is available. The capture loop keeps a short backlog to carry audio
through brief TCP write stalls. Queued waves expire after 120 ms with
`--audio-core-tap` or 80 ms with ScreenCaptureKit. If the backlog fills, the
capture loop discards the oldest pending wave and logs the drop count. At most
one additional wave waits in the transport channel. Client playback buffering
and network transit also contribute to the delay heard at the speakers.

On the local `--stats-endpoint`, `pcm_queue_age_samples` and
`pcm_queue_age_total_us` measure time from packet assembly to transport handoff.
`pcm_queue_drops` counts expired and evicted packets. These process-wide values
exclude packets already in the TCP writer and client playback buffering.

To compare RDPSND acknowledgements with TCP stalls, run a diagnostic session
with `RUST_LOG=info,ironrdp_rdpsnd::server=trace`, then summarize the log using
a time window for that connection.

```sh
python3 scripts/summarize-audio-diagnostics.py \
  --since 2026-11-22T19:12:00Z --until 2026-11-22T19:13:07Z
```

The report groups first and second confirmations separately. Their timestamps
measure the client's receive-to-confirm time. TCP stall summaries cover only
writes the server logged as stalled and can include other graphics or
redirection channels. Compare audio with a matching flash and beep recorded
on the client to measure playback sync.

For a screen recording with five flash-and-beep pulses and system audio, run
`swift scripts/measure-av-sync.swift recording.mp4` on the Mac. The script uses
the middle half of the frame in both dimensions. To measure a smaller flash
area, pass its normalized `x,y,width,height` as the next argument. It reports
each pair and the median in milliseconds. A positive value means the beep
occurred after the flash. Allow for the recording's video frame interval and the
script's 5 ms audio windows when comparing results.

## Microphone redirection (experimental)

The other direction: **the client's microphone becomes a real input device on
the Mac**, "macrdp Microphone", which Zoom, FaceTime, QuickTime and Teams can
record from. Off by default; turn it on with `--enable-microphone-redirection`
(config `ENABLE_MICROPHONE_REDIRECTION=1`, or the controller's Settings →
Redirection → Microphone toggle).

**Setup, once:** install the "macrdp Microphone" driver from the menu-bar
controller — Settings → Redirection → Microphone → **Install macrdp
Microphone…**. It asks for an administrator password and restarts Core Audio,
which briefly interrupts sound. The same place shows when a newer macrdp bundles
a newer driver (**Update…**) and removes it (**Remove…**). Without a controller,
run `/Applications/macrdp.app/Contents/Resources/install-audio-plugin.sh`.

**On the client:** mstsc → Local Resources → Remote audio → Settings →
**Record from this computer**, set before connecting. FreeRDP: `/microphone`.

**What to expect:** the device carries the client's audio with about 100 ms of
latency, and reads as silence when no session is streaming. After a network
stall it skips ahead to stay current rather than playing late audio, which can
cause a brief click.

**Limits:**
- **Other people's accounts on this Mac can listen in** while a session is
  streaming. They can't inject audio, and nothing is kept after the session ends.
  On a Mac with other user accounts, treat an active redirected mic as audible to
  them. (Why: `docs/macos-gotchas.md`, item 5.)
- **44.1 kHz only for now** (16-bit PCM). mstsc offers it. A client that can't
  gets no mic, and macrdp logs why.

**Debugging:** `MIC_DUMP=1` in `config.env` (env `MACRDP_MIC_DUMP=1`) writes
the received audio to a WAV file under `$TMPDIR` instead of feeding the device —
play it back to check what the client actually sent.
