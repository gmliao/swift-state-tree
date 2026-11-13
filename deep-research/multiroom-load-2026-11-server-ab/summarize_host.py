#!/usr/bin/env python3
"""Summarize the Windows host's total CPU over each run's steady measured window.

Reads the host samples of the raw result set (one JSON line per second with the host's total
CPU in `total`, % of the whole machine, and a wall clock `ts` in seconds) and this topic's
reports, and writes data/host-cpu.json with the mean and p95 of `total` per run. Only these
summary figures are published; the per-process samples stay in the raw set.

Two samplers ran for the A/B steps, with overlapping spans (the smoke sampler kept running into
the matrix), so each run reads only the file started for its step (`sampler` below), not the
union. The diagnosis runs (`diag-*`) come from a separate raw set with its own sampler.

Each invocation updates the runs whose sampler file is in the given directory and keeps the
other entries of data/host-cpu.json as they are, so the two raw sets are summarized one at a time.

Usage: python3 summarize_host.py <a raw result set's meta/ directory>
"""
import gzip
import json
import math
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

def sampler(run):
    """The host sampler that covered a run: the smoke pair's, the A/B steps', or the diagnosis set's."""
    if run.startswith("diag-"):
        return "diag-host.jsonl"
    return "ab-host-smoke.jsonl" if run.startswith("smoke-") else "ab-host-matrix.jsonl"


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
    path = HERE / "data" / "host-cpu.json"
    out = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    for run_dir in sorted((HERE / "data" / "runs").iterdir()):
        if not (meta / sampler(run_dir.name)).exists():
            continue
        samples = []
        for line in (meta / sampler(run_dir.name)).read_text(encoding="utf-8").splitlines():
            if line.strip():
                row = json.loads(line)
                samples.append((row["ts"] * 1000.0, row["total"]))
        with gzip.open(run_dir / "report.json.gz", "rt", encoding="utf-8") as f:
            start, end = steady_window(json.load(f))
        inside = [total for ts, total in samples if start <= ts < end]
        out[run_dir.name] = {
            "sampler": sampler(run_dir.name),
            "samples": len(inside),
            "totalMeanPct": round(sum(inside) / len(inside), 1) if inside else None,
            "totalP95Pct": nearest_rank(inside, 0.95) if inside else None,
        }
    path.write_text(json.dumps(out, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
