#!/usr/bin/env python3
"""Writes a calibration (calibration.py) from fresh U-P0 and M-P0 runs at the sweep's commit
(stdlib only). `run.sh` MODE=calibrate runs the two P0 runs, then this.

  calibrate.py --u-p0 data/<run-id> --m-p0 data/<run-id> --name <name> --out <file.json>

- **P0 downstream** of each population: lt-client's downstream netem (veth-c1, root handle 1:) in
  qdisc bytes per second, from impair.sh sample-backlog's samples (netem-backlog.jsonl): the
  growth of its sent bytes from the first sample at or after the baseline's start to the last at
  or before the recovery's end, over the time between them (design § 3: "P0 downstream is
  measured per load point and per population, in qdisc bytes per second").
- **RATE and COMBO** (calibration.RATE_CELLS): rate = fraction × that downstream, limit by § 1.
- **The wire form** is what the P0 runs' joins named (run.json meta.wireForms), one form over
  both runs and every instance, or the calibration is refused.
- **Carried over** from the built-in calibration, stated in the file: the fixed limits (§ 1) and
  the jitter cells' reordering, which depends on netem's packet rate, not on payload size.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC))
sys.path.insert(0, str(TOPIC.parent))
import calibration  # noqa: E402

BASELINE_MS = 30_000
RECOVERY_MS = 90_000


def segments(run_dir: pathlib.Path) -> tuple[int, int]:
    """[baseline start, recovery end] in epoch ms, from the timeline's apply and lift."""
    entries = json.loads((run_dir / "impairment-timeline.json").read_text())
    apply = next(e for e in entries if e["action"] == "apply")["wallMsAfter"]
    lift = next(e for e in entries if e["action"] == "lift")["wallMsAfter"]
    return int(apply - BASELINE_MS), int(lift + RECOVERY_MS)


def downstream_bytes_per_s(run_dir: pathlib.Path) -> float:
    start, end = segments(run_dir)
    samples = []
    for line in (run_dir / "netem-backlog.jsonl").read_text().splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        down = next((q for q in row["qdiscs"] if q.get("kind") == "netem" and q.get("handle") == "1:" and q.get("parent") == "root"), None)
        if down is not None and "sentBytes" in down and start <= row["t"] <= end:
            samples.append((row["t"], down["sentBytes"]))
    if len(samples) < 2 or samples[-1][0] - samples[0][0] < 10_000:
        raise SystemExit(f"{run_dir}: too few downstream samples between {start} and {end} ({len(samples)})")
    (t0, b0), (t1, b1) = samples[0], samples[-1]
    return (b1 - b0) * 1000 / (t1 - t0)


def wire_key(run_dir: pathlib.Path) -> str:
    forms = json.loads((run_dir / "run.json").read_text())["meta"].get("wireForms") or {}
    keys = {k for counts in forms.values() for k, n in (counts or {}).items() if n}
    if not forms or any(v is None for v in forms.values()) or len(keys) != 1:
        raise SystemExit(f"{run_dir}: the joins' wire form isn't one recorded form: {forms}")
    return keys.pop()


def build(u_p0: pathlib.Path, m_p0: pathlib.Path, name: str) -> dict:
    key = wire_key(u_p0)
    if wire_key(m_p0) != key:
        raise SystemExit(f"U-P0 ran {key}, M-P0 ran {wire_key(m_p0)}: one calibration needs one wire form")
    encoding, _, features = key.partition(":")
    commit = json.loads((u_p0 / "run.json").read_text())["meta"]["git"]["commit"]
    down = {"U": downstream_bytes_per_s(u_p0), "M": downstream_bytes_per_s(m_p0)}
    cells = json.loads(json.dumps(calibration.BUILTIN["cells"]))
    for cell, (population, fraction) in calibration.RATE_CELLS.items():
        cells[cell].update(calibration.rate_settings(down[population], fraction))
    return {
        "name": name,
        "commit": commit,
        "encoding": encoding,
        # "none": the server echoed no features (it omits an empty list), both off.
        "features": [] if features == "none" else features.split(","),
        "p0DownstreamBytesPerS": {p: round(v) for p, v in down.items()},
        "sources": {"U-P0": u_p0.name, "M-P0": m_p0.name},
        "carriedOver": {"from": calibration.BUILTIN["name"], "what": "fixed limits and the jitter cells' reordering"},
        "cells": cells,
    }


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--u-p0", type=pathlib.Path, required=True)
    ap.add_argument("--m-p0", type=pathlib.Path, required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--out", type=pathlib.Path, required=True)
    args = ap.parse_args(argv)
    result = build(args.u_p0, args.m_p0, args.name)
    args.out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(args.out)
    for cell in calibration.RATE_CELLS:
        print(f"  {cell}: rate {result['cells'][cell]['rate']}, limits {result['cells'][cell]['limits']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
