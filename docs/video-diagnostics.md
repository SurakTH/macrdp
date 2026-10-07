# Diagnosing stale H.264 output

These counters locate stalls without recording pixels, key values, terminal
contents, credentials, or packet payloads. They do not prove that Windows
presented a frame. H.264's reported typing delay remains under live investigation. The current
flush scheduler sends ordinary trailing pictures immediately at frame cadence,
then retains the quiet-period IDR and a second trailing burst for recovery.
The Windows typing result still needs confirmation after rebuilding.

Enable the existing local endpoint with `--stats-endpoint` or
`STATS_ENDPOINT=1` in config.env, then restart the server when no session is
in use. The endpoint listens only on 127.0.0.1 (default port 40245).

On the Mac, start a recording:

```sh
python3 scripts/collect-video-diagnostics.py --seconds 60 --output video-stall.jsonl
```

Use the Windows terminal for a short, repeatable test: type several lines
quickly, press Enter, stop for five seconds without moving the mouse, then move
the mouse. Note when the screen catches up. Repeat with bitmap as a control;
compare another client when available. Preserve macrdp.log from the same run.
The collector does not restart the server or change its settings.

## Reading the recording

Each line contains a UTC time, snapshot and counter deltas. An error line means
the endpoint was unavailable or incompatible, not that the video is frozen.
Counters are process-wide and cumulative; restart changes process_id. Reconnect
is not a reset. Read changes over a window, not exact equality between atomic
values sampled at slightly different times.

- `keyboard_events`: received keyboard events, including releases. No key values.
- `capture_samples`: all samples consumed from ScreenCaptureKit.
- `capture_idle`: non-content samples (includes blank/suspended states).
- `capture_content`: content samples with a usable image buffer.
- `encode_submitted`: logical H.264 capture submissions accepted by the encoder,
  including refresh pictures.
- `encode_deferred`: submission attempts postponed by throttles or unavailable
  state; not a count of permanently lost frames.
- `encoded_pictures`: usable VideoToolbox output pictures. AVC444 normally emits
  two per logical submission; AVC420 emits one.
- `encode_output_errors`: callbacks without a usable picture or extraction
  failures. Logs include the associated status, without image contents.
  Failed encoder pictures now produce a completion outcome, release their
  logical pipeline slot (once per AVC444 pair), and request a recovery IDR.
- `transport_retired`: logical frames whose transport event completed OR was
  abandoned on error/disconnect. Consult logs for failures. It is neither a
  count of bytes received by Windows nor proof of decoding/presentation.

Increasing key counts with no content capture suggests checking capture first.
Submissions without output, especially with callback errors, suggest checking
VideoToolbox. Output without transport retirement suggests dispatch/transport.
If all stages advance, investigate client acknowledgements and rendering next;
server-side counters alone cannot distinguish those final stages.

Disabling the endpoint makes these diagnostic counter updates no-ops. Existing
GUI fields are preserved, and the new fields are additive.
