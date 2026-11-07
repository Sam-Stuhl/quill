#!/usr/bin/env python3
"""Latency report from ~/quill/.quill/events.jsonl.

    measure.py [--since MINUTES]

upload lag: the app's write time (X-Quill-Written-At) to the server having the
file on disk, per kind (file = native note files, pdf = rendered PDF). Pen lift
to save adds the autosave delay (1 s) in front of these.
inbox lag: the file first seen in Inbox/ to Quill's ack after importing it.
"""
import argparse
import json
import os
import statistics
import time
from pathlib import Path


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1))))]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", type=float, default=60, help="minutes back (default 60)")
    a = ap.parse_args()
    root = Path(os.environ.get("QUILL_ROOT", Path.home() / "quill"))
    cutoff = (time.time() - a.since * 60) * 1000
    lags = {}
    for line in (root / ".quill/events.jsonl").read_text(encoding="utf-8").splitlines():
        ev = json.loads(line)
        if ev["t"] < cutoff or "lag_ms" not in ev:
            continue
        lags.setdefault(ev["ev"], []).append(ev["lag_ms"])
    if not lags:
        print("no events with timings in that window")
    for kind, xs in sorted(lags.items()):
        print(f"{kind:16} n={len(xs):4}  p50={pct(xs, 50):6} ms  p95={pct(xs, 95):6} ms  "
              f"max={max(xs):6} ms  mean={statistics.mean(xs):8.0f} ms")


if __name__ == "__main__":
    main()
