#!/usr/bin/env python3
"""Summarize timing metadata from a local macrdp log."""

import argparse
import datetime
import json
import math
import re
import statistics
from pathlib import Path


TIMESTAMP = re.compile(r"^(\d{4}-\d{2}-\d{2}T[^ ]+Z) ")
CONFIRM = re.compile(r"Received (second )?RDPSND wave confirm .*\bheld_ms=(\d+)")
TCP_STALL = re.compile(
    r"SharedWriter\.write_all stalled.*\bbytes=\d+ lock_wait_ms=(\d+) write_ms=(\d+)"
)
PCM_DROP = re.compile(r"PCM send queue hit latency limit \bdropped=(\d+)")


def utc_timestamp(value):
    try:
        timestamp = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise argparse.ArgumentTypeError("expected an ISO 8601 timestamp") from error
    if timestamp.tzinfo is None:
        raise argparse.ArgumentTypeError("include the UTC offset, for example 2026-11-22T19:12:00Z")
    return timestamp


def distribution(values):
    if not values:
        return {"samples": 0}
    values.sort()
    return {
        "samples": len(values),
        "median_ms": statistics.median(values),
        "p95_ms": values[math.ceil(len(values) * 0.95) - 1],
        "max_ms": values[-1],
    }


def summarize(lines, start, end):
    first, second, tcp_wait, tcp_write = [], [], [], []
    pcm_drops = 0
    for line in lines:
        stamp = TIMESTAMP.match(line)
        if not stamp:
            continue
        time = utc_timestamp(stamp[1])
        if (start is not None and time < start) or (end is not None and time >= end):
            continue
        if match := CONFIRM.search(line):
            (second if match[1] else first).append(int(match[2]))
        if match := TCP_STALL.search(line):
            tcp_wait.append(int(match[1]))
            tcp_write.append(int(match[2]))
        if match := PCM_DROP.search(line):
            pcm_drops += int(match[1])
    return {
        "first_confirm_client_hold": distribution(first),
        "second_confirm_client_hold": distribution(second),
        "logged_tcp_stall_lock_wait": distribution(tcp_wait),
        "logged_tcp_stall_write_time": distribution(tcp_write),
        "logged_pcm_queue_drops": pcm_drops,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path, default=Path.home() / "Library/Logs/macrdp.log")
    parser.add_argument("--since", type=utc_timestamp)
    parser.add_argument("--until", type=utc_timestamp)
    args = parser.parse_args()
    if args.since is not None and args.until is not None and args.since >= args.until:
        parser.error("--until must be later than --since")
    try:
        with args.log.open(encoding="utf-8", errors="replace") as lines:
            print(json.dumps(summarize(lines, args.since, args.until), indent=2))
    except OSError as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
