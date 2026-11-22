#!/usr/bin/env python3
"""Summarize macrdp recordings without mixing restarts or video sessions."""

import argparse
import json
import math
from pathlib import Path


IDENTITY_FIELDS = ("process_id", "video_generation", "width", "height", "fps")
COUNTERS = (
    "video_frames_queued", "video_payload_bytes", "encode_completed",
    "encode_total_us", "encode_output_errors", "keyboard_events",
)


def segments(path):
    current = []
    identity = None
    for line in path.read_text(encoding="utf-8").splitlines():
        row = json.loads(line).get("snapshot")
        if row is None or row.get("video_active") is False or not row.get("width"):
            key = None
        else:
            key = tuple(row.get(field) for field in IDENTITY_FIELDS)
        if key != identity or (current and counters_reset(current[-1], row)):
            if current:
                yield current
            current = []
        if key is not None:
            current.append(row)
        identity = key
    if current:
        yield current


def counters_reset(previous, current):
    return current["uptime_ms"] <= previous["uptime_ms"] or any(
        current[counter] < previous[counter] for counter in COUNTERS
    )


def summary(samples):
    first, last = samples[0], samples[-1]
    seconds = (last["uptime_ms"] - first["uptime_ms"]) / 1000
    if seconds <= 0:
        return None

    def delta(key):
        return last[key] - first[key]

    retained = ""
    if all("encode_retained_submitted" in sample for sample in samples):
        retained_rate = delta("encode_retained_submitted") / seconds
        total_rate = delta("encode_submitted") / seconds
        retained = f" | encode submits/s {retained_rate:.1f} retained of {total_rate:.1f} total"

    fps = delta("video_frames_queued") / seconds
    rate = delta("video_payload_bytes") * 8 / seconds / 1_000_000
    count = delta("encode_completed")
    encode = f"{delta('encode_total_us') / count / 1000:.1f} ms" if count > 0 else "n/a"
    preparation = ""
    if all("encode_prepared" in sample and "encode_prepare_total_us" in sample for sample in samples):
        prepared = delta("encode_prepared")
        prepare_us = delta("encode_prepare_total_us")
        if prepared > 0 and prepare_us >= 0:
            preparation = f" | mean AVC420 buffer preparation {prepare_us / prepared / 1000:.2f} ms"
    timings = ""
    for name, label in (
        ("capture_to_submit", "capture callback to encoder submit"),
        ("tcp_dispatch", "queue to TCP write completion"),
    ):
        count_key, total_key = f"{name}_samples", f"{name}_total_us"
        if all(count_key in sample and total_key in sample for sample in samples):
            completed, total_us = delta(count_key), delta(total_key)
            if completed > 0 and total_us >= 0:
                timings += f" | mean {label} {total_us / completed / 1000:.2f} ms (n={completed})"
    tcp_pacing = ""
    if all("encode_tcp_backpressure" in sample for sample in samples):
        tcp_pacing = f" | TCP-paced submissions deferred {delta('encode_tcp_backpressure')}"
    submit_errors = ""
    if all("encode_submit_errors" in sample for sample in samples):
        submit_errors = f" | encoder submission errors {delta('encode_submit_errors')}"
    ship_errors = ""
    if all("video_ship_errors" in sample for sample in samples):
        ship_errors = f" | AVC420 shipping errors {delta('video_ship_errors')}"
    superseded = ""
    if all("capture_superseded" in sample for sample in samples):
        superseded = f" | superseded capture samples {delta('capture_superseded')}"
    unique_acks = {}
    for sample in samples:
        ack = sample.get("ack_samples", 0)
        if ack and first["uptime_ms"] < sample["ack_sample_uptime_ms"] <= sample["uptime_ms"]:
            unique_acks[ack] = sample["ack_queue_ms"]
    if unique_acks:
        queue = sorted(unique_acks.values())
        ack_delay = (
            f"p95 {queue[math.ceil(len(queue) * .95) - 1]} ms, "
            f"peak {queue[-1]} ms (n={len(queue)})"
        )
    else:
        ack_delay = "n/a"
    return (f"{last['width']}x{last['height']} / {last['fps']} FPS limit | "
            f"{seconds:.1f} s | queued FPS {fps:.1f} | payload {rate:.1f} Mbps | "
            f"mean encoder completion {encode} | sampled ACK queue {ack_delay} | "
            f"encoder errors {delta('encode_output_errors')} | "
            f"keyboard events {delta('keyboard_events')}{retained}{preparation}{tcp_pacing}"
            f"{submit_errors}{ship_errors}{superseded}{timings}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recordings", type=Path, nargs="+")
    args = parser.parse_args()
    for path in args.recordings:
        print(path.name)
        try:
            summaries = [result for samples in segments(path) if (result := summary(samples))]
        except (OSError, KeyError, TypeError, ValueError) as error:
            parser.exit(2, f"{path}: unsupported or incomplete diagnostic recording: {error}\n")
        for result in summaries:
            print(f"  {result}")
        if not summaries:
            print("  No active video interval with at least two samples.")
    print("Queued frames and sampled ACK delay do not measure Windows presentation or input latency.")


if __name__ == "__main__":
    main()
