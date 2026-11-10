#!/usr/bin/env python3
"""Whether a run's Hero Defense load is stationary over its measured segments (#425), from the
server's per-land stats (``land-stats.jsonl``). Stdlib only.

  stationarity.py <data/<run-id>>     exit 0 and the table when stationary, 1 when not or when
                                      an input is missing (with the reason)

The rule:
- Bin the run in 10 s bins from the baseline's start (the end of the warm-up) to the end of the
  recovery segment.
- Per bin, take the median over every land of its live monster count, over every 1 s line in
  the bin.
- **Stationary** when the coefficient of variation (population stdev / mean) of those per-bin
  medians is at most ``COV_BOUND``, no bin's median is more than ``MAX_DEV`` from their mean, and
  the run ran without the spawn ramp: ``params.spawnRampTicks`` and the server's own
  ``meta.spawnRampTicksEffective`` are both 0.

It also prints, per bin, the flows behind the count (the median over lands of each land's
spawned, killed and reached-base totals' change per second) and the median base health.
"""
from __future__ import annotations

import json
import math
import pathlib
import statistics
import sys

COV_BOUND = 0.10
MAX_DEV = 0.20
BIN_MS = 10_000
BASELINE_MS = 30_000
RECOVERY_MS = 90_000
FLOWS = ("spawned", "killed", "reachedBase")


class Missing(ValueError):
    pass


def check(run_dir: pathlib.Path) -> tuple[bool, list[str]]:
    """(stationary, the report's lines)."""
    for name in ("run.json", "impairment-timeline.json", "land-stats.jsonl"):
        if not (run_dir / name).exists():
            raise Missing(f"{run_dir}: no {name}")
    record = json.loads((run_dir / "run.json").read_text())
    ramp = (record.get("params") or {}).get("spawnRampTicks")
    effective = (record.get("meta") or {}).get("spawnRampTicksEffective")
    timeline = json.loads((run_dir / "impairment-timeline.json").read_text())
    try:
        applied = next(e for e in timeline if e["action"] == "apply")["wallMsAfter"]
        lifted = next(e for e in timeline if e["action"] == "lift")["wallMsAfter"]
    except (StopIteration, KeyError):
        raise Missing(f"{run_dir}: the timeline has no apply and lift") from None
    start, end = applied - BASELINE_MS, lifted + RECOVERY_MS
    live: dict[int, list[int]] = {}
    base: dict[int, list[int]] = {}
    first: dict[tuple[int, str], tuple[int, dict]] = {}
    last: dict[tuple[int, str], tuple[int, dict]] = {}
    for raw in (run_dir / "land-stats.jsonl").read_text().splitlines():
        if not raw.strip():
            continue
        line = json.loads(raw)
        if not start <= line["ts"] < end:
            continue
        k = (line["ts"] - start) // BIN_MS
        for land, sample in line["lands"].items():
            live.setdefault(k, []).append(sample["monsters"])
            base.setdefault(k, []).append(sample["baseHealth"])
            first.setdefault((k, land), (line["ts"], sample))
            last[(k, land)] = (line["ts"], sample)
    if not live:
        raise Missing(f"{run_dir}: no land-stats line between the baseline's start and the recovery's end")

    def rate(k: int, flow: str) -> float:
        rates = [(last[key][1].get(flow, 0) - a.get(flow, 0)) / ((last[key][0] - ta) / 1000)
                 for key, (ta, a) in first.items() if key[0] == k and last[key][0] > ta]
        return statistics.median(rates) if rates else math.nan

    out = [f"{run_dir.name}: spawn ramp {ramp} (params), {effective} (server); {BIN_MS // 1000} s bins from the "
           f"baseline's start to the recovery's end ({(end - start) // 1000} s)",
           "     s | live monsters, median (p10-p90) | spawned / killed / reached base per s per land | base health"]
    medians = []
    for k in sorted(live):
        counts = sorted(live[k])
        median = statistics.median(counts)
        medians.append(median)
        flows = " / ".join(f"{rate(k, f):5.2f}" for f in FLOWS)
        out.append(f"  {k * BIN_MS // 1000:4d} | {median:5.1f} ({counts[len(counts) // 10]}-{counts[9 * len(counts) // 10]}) | "
                   f"{flows} | {statistics.median(base[k]):5.1f}")
    mean = statistics.mean(medians)
    cov = statistics.pstdev(medians) / mean if mean else math.inf
    dev = max(abs(m - mean) / mean for m in medians) if mean else math.inf
    no_ramp = ramp == 0 and effective == 0
    stationary = cov <= COV_BOUND and dev <= MAX_DEV and no_ramp
    out.append(f"per-bin medians: mean {mean:.1f}, CoV {cov:.3f} (bound {COV_BOUND}), largest deviation {dev:.1%} "
               f"(bound {MAX_DEV:.0%}); spawn ramp {'0 in params and from the server' if no_ramp else 'not 0'}")
    out.append("STATIONARY" if stationary else "NOT STATIONARY")
    return stationary, out


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    try:
        stationary, lines = check(pathlib.Path(argv[0]))
    except (Missing, json.JSONDecodeError) as e:
        print(f"stationarity.py: {e}", file=sys.stderr)
        return 1
    print("\n".join(lines))
    return 0 if stationary else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
