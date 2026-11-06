#!/usr/bin/env python3
"""Summarize the server's context switches over each diagnosis run's steady measured window.

Reads the per-second samples of the diagnosis raw set (`meta/chain/<run>.ctx.jsonl`: once per
second, every thread of the GameServer process with its cumulative `voluntary_ctxt_switches` and
`nonvoluntary_ctxt_switches` from /proc) and this topic's reports, and writes data/diag-ctx.json
with the switches per second of the whole process, two ways:

- `allThreads`: every thread seen inside the window. A thread's count is its last in-window value
  minus its first in-window value, so a thread created inside the window counts from its first
  sample (missing at most a second of its switches), and a thread the sampler skipped in the
  window's first sample (a /proc read it couldn't complete) doesn't add its switches from before
  the window.
- `wholeWindow`: only the threads present in both the window's first and last sample.

The two differ by the threads the process creates or ends inside the window (the cooperative
pool grows under load). The figures aren't split by thread kind: Linux gives a new thread its
creator's name, so a pool thread created from an event loop carries the event loop's name.

Window: the first and the last sample inside the steady phase's measured window.

Only these summary figures are published; the per-second samples stay in the raw set.

Usage: python3 summarize_ctx.py <the diagnosis raw set's meta/ directory>
"""
import gzip
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def steady_window(report):
    """[start, end) in ms of the steady phase's measured window."""
    phase = next(p for p in report["phases"] if p["name"] == "steady")
    m = phase["measurement"]
    return m["originAt"] + m["warmupMs"], m["originAt"] + m["warmupMs"] + m["measuredMs"]


def summarize(samples, start, end):
    inside = [s for s in samples if start <= s["t"] < end]
    first, last = inside[0], inside[-1]
    seconds = (last["t"] - first["t"]) / 1000.0
    at_first, latest = {}, {}
    for s in inside:
        for tid, _, v, nv in s["th"]:
            at_first.setdefault(tid, (v, nv))
            latest[tid] = (v, nv)
    whole = {t[0] for t in first["th"]} & {t[0] for t in last["th"]}

    def rates(tids):
        v = sum(latest[t][0] - at_first[t][0] for t in tids)
        nv = sum(latest[t][1] - at_first[t][1] for t in tids)
        return {"threads": len(tids), "voluntaryPerSecond": round(v / seconds),
                "nonvoluntaryPerSecond": round(nv / seconds)}

    return {
        "windowSeconds": round(seconds, 1),
        "samples": len(inside),
        "allThreads": rates(set(latest)),
        "wholeWindow": rates(whole),
    }


def main():
    chain = Path(sys.argv[1]) / "chain"
    out = {}
    for run_dir in sorted((HERE / "data" / "runs").iterdir()):
        source = chain / f"{run_dir.name}.ctx.jsonl"
        if not source.exists():
            continue
        samples = []
        for line in source.read_text().splitlines():
            row = json.loads(line) if line.strip() else None
            if row and "th" in row:
                samples.append(row)
        with gzip.open(run_dir / "report.json.gz", "rt") as f:
            start, end = steady_window(json.load(f))
        out[run_dir.name] = summarize(samples, start, end)
    (HERE / "data" / "diag-ctx.json").write_text(json.dumps(out, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
