# Daily use validation

Keep the installed build as a fallback. In the preview set the same display
size, capture FPS, bitrate and transport as in the installed build. Leave Fast
flush and Responsive capture off for the first comparison; toggle one option
at a time afterward. Stop the Brew server before starting the preview on the
same port.

## Automated checks

```sh
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
swift test --package-path gui
MACRDP_TCP_SOAK_RECONNECTS=250 cargo test --locked real_disconnect_releases_input_before_reconnect -- --nocapture
```

The TCP soak runs a test server and an IronRDP client on loopback. It alternates
1280×800 and 1920×1080 and requires a cleanup callback after every disconnect
before starting the next one. It uses test credentials and display/input
doubles; it does not establish Windows mstsc performance, macOS input behavior,
or ScreenCaptureKit reliability.

`client_monitor_layout_reactivates_existing_connection` sends a client monitor
layout over the Display Control channel, completes reactivation at the requested
dimensions, and verifies that the server receives keyboard input over the same
transport. The Windows acceptance run still needs to exercise captured image
recovery and pointer alignment after a live resize.

## Windows acceptance

For a daily-use trial, start with a fixed 1920×1080 size and a 60 FPS capture
limit. In **Connection → Personal presets**, save the settings you tested
under a name such as `Daily · 1080p60`. **Save New** records the current
Controller values without restarting the server. Load the preset and review
its settings before applying it in a later session.

Run the baseline for a normal work session and record the Windows version,
RDP client, network, Mac display, build, and settings used. Retain a specific
reproduction for anything that goes wrong:

- Fresh connect, reconnect after both a client close and a network interruption,
  minimize/restore, idle and resize with automatic client size enabled.
- For H.264 restore, leave a static document open, minimize mstsc for several
  seconds, then restore it without moving the pointer inside the session.
  The document should reappear before any new input. Repeat after a live resize
  and check that the restored image uses the new size.
- Sustained typing, fast scroll reversal, dragging and modifier clicks. Check
  for stale input after a disconnect during a drag or held key.
- Copy text, images and files in both directions, including an iPhone Handoff
  item if Universal Clipboard is enabled.
- Diagnostic graphs stop reporting the ended session and show the next one.
  Export an RDP shortcut and verify its address and port on Windows.
- If you see picture corruption, record the resolution and Fast flush
  interval, then repeat the same action at the same resolution with Fast
  flush off. Apply when you can reconnect.

The main performance comparison is whether typing and motion look responsive
without artifacts. The Controller's encode and ACK metrics help explain a
problem but do not replace measuring or observing Windows presentation.

With the diagnostics endpoint enabled on loopback, collect and compare equal
intervals while repeating the same typing, scrolling and idle sequence at each
resolution. Use a fresh output filename for each run.

```sh
python3 scripts/collect-video-diagnostics.py --seconds 25 --output windows-4k.jsonl
python3 scripts/collect-video-diagnostics.py --seconds 25 --output windows-1080p.jsonl
python3 scripts/summarize-video-diagnostics.py windows-4k.jsonl windows-1080p.jsonl
```

The summary splits recordings across video sessions and counter resets. The
ACK percentile uses the latest ACK observed at each poll. Keyboard totals count
events received by the server.
Newer recordings also report accepted submissions from retained captures
(flush, repaint and deferred retries). This helps explain how the queued
frame rate can exceed the ScreenCaptureKit capture setting during bursts.
With newer AVC420 builds, the summary also reports buffer preparation time.
Compare it with encoder completion time to distinguish buffer allocation and
pixel conversion from the wait after submitting to VideoToolbox.

To estimate local 4K AVC420 throughput separately from screen capture, RDP
transport and the Windows decoder, run the release-mode benchmark with
synthetic frames:

```sh
cargo test --locked --release bench_avc420_4k_pipeline_depth -- --ignored --nocapture
```

The benchmark limits in-flight encoder submissions to one and two frames,
and counts completed pictures in standard and VideoToolbox low-latency
modes. The low-latency mode is available in the benchmark only. Other
processes, including an active macrdp session, can affect the rates.

For an ACK delay spike around minimize or restore, compare the change in
queued frames and ACKs in adjacent samples. A flat frame count while ACKs
continue indicates previously queued frames are still being acknowledged.
If the log also reports a UDP tunnel timeout, repeat with **Advanced →
Offer UDP multitransport** off and keep the video settings fixed. Compare
what the client displays during both runs.
