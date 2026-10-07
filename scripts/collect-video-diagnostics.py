#!/usr/bin/env python3
"""Collect local macrdp counters; never captures pixels or keyboard contents."""
import argparse
import datetime
import json
import socket
import sys
import time
from pathlib import Path

COUNTERS = (
    "keyboard_events", "capture_samples", "capture_content", "capture_idle",
    "encode_submitted", "encode_deferred", "encoded_pictures",
    "encode_output_errors", "transport_retired",
)


def read_snapshot(port):
    # A fixed loopback address prevents accidentally collecting another host.
    with socket.create_connection(("127.0.0.1", port), timeout=1) as stream:
        stream.settimeout(1)
        data = bytearray()
        deadline = time.monotonic() + 2
        while b"\n" not in data:
            if time.monotonic() > deadline:
                raise TimeoutError("stats response exceeded two seconds")
            chunk = stream.recv(4096)
            if not chunk:
                break
            data.extend(chunk)
            if len(data) > 65536:
                raise ValueError("stats response exceeds 64 KiB")
    snapshot = json.loads(data)
    if not isinstance(snapshot, dict) or snapshot.get("diagnostics_version") != 1:
        raise ValueError("server does not have video diagnostics; install the diagnostic build")
    if any(type(snapshot.get(key)) is not int or snapshot[key] < 0 for key in COUNTERS):
        raise ValueError("missing or invalid diagnostic counters")
    return snapshot


def deltas(previous, current):
    if previous is None or previous.get("process_id") != current.get("process_id"):
        return None
    if any(current[key] < previous[key] for key in COUNTERS):
        return None
    return {key: current[key] - previous[key] for key in COUNTERS}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=40245)
    parser.add_argument("--seconds", type=int, default=60)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.port <= 65535 or not 1 <= args.seconds <= 3600:
        parser.error("port must be 1..65535 and seconds 1..3600")
    previous = None
    successful = 0
    started = time.monotonic()
    # Refuse to overwrite an earlier diagnostic recording.
    with args.output.open("x", encoding="utf-8") as output:
        while time.monotonic() - started < args.seconds:
            record = {"time": datetime.datetime.now(datetime.timezone.utc).isoformat()}
            try:
                current = read_snapshot(args.port)
                record.update(snapshot=current, delta=deltas(previous, current))
                previous = current
                successful += 1
            except (OSError, ValueError) as error:
                record["error"] = str(error)
                previous = None
            output.write(json.dumps(record) + "\n")
            output.flush()
            time.sleep(0.25)
    if successful == 0:
        print(f"No diagnostic snapshots received. Check --stats-endpoint; errors saved to {args.output}", file=sys.stderr)
        return 2
    print(f"Saved {successful} diagnostic snapshots to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
