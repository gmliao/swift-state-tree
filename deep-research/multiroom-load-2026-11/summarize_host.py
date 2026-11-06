#!/usr/bin/env python3
"""Summarize the Windows host's total CPU over each run's steady measured window.

Reads the host samples of the raw result set (one JSON line per second with the host's total
CPU in `total`, % of the whole machine, and a wall clock `ts` in seconds) and this topic's
reports, and writes data/host-cpu.json with the mean and p95 of `total` per run. Only these
summary figures are published; the per-process samples stay in the raw set.

Several samplers ran at once with overlapping spans, so each run reads only the file that was
started for its step (SAMPLER below), not the union.

Usage: python3 summarize_host.py <raw result set's meta/ directory>
"""
import gzip
import json
import math
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

SAMPLER = {
    "preflight": "host-preflight.jsonl",
    "overhead-profiled": "host-step3.jsonl",
    "overhead-unprofiled": "host-step3.jsonl",
}
for suite in (1, 2, 3):
    for rooms in (100, 300, 500):
        SAMPLER[f"rerun-suite-{suite}-{rooms}"] = f"host-rerun-suite{suite}.jsonl"


def steady_window(report):
    """[start, end) in ms of the steady phase's measured window."""
    phase = next(p for p in report["phases"] if p["name"] == "steady")
    m = phase["measurement"]
    return m["originAt"] + m["warmupMs"], m["originAt"] + m["warmupMs"] + m["measuredMs"]


def nearest_rank(values, p):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, math.ceil(p * len(ordered)) - 1))]


def main():
    meta = Path(sys.argv[1])
    out = {}
    for run_dir in sorted((HERE / "data" / "rerun").iterdir()):
        samples = []
        for line in (meta / SAMPLER[run_dir.name]).read_text().splitlines():
            if line.strip():
                row = json.loads(line)
                samples.append((row["ts"] * 1000.0, row["total"]))
        with gzip.open(run_dir / "report.json.gz", "rt") as f:
            start, end = steady_window(json.load(f))
        inside = [total for ts, total in samples if start <= ts < end]
        out[run_dir.name] = {
            "sampler": SAMPLER[run_dir.name],
            "samples": len(inside),
            "totalMeanPct": round(sum(inside) / len(inside), 1) if inside else None,
            "totalP95Pct": nearest_rank(inside, 0.95) if inside else None,
        }
    (HERE / "data" / "host-cpu.json").write_text(json.dumps(out, indent=2, sort_keys=True) + "\n")
    print(json.dumps(out, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
