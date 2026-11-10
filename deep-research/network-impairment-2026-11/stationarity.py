#!/usr/bin/env python3
"""Whether a run's Hero Defense load is stationary over its measured segments (#425), from the
server's per-land stats (``land-stats.jsonl``). Stdlib only.

  stationarity.py <data/<run-id>>     exit 0 and the table when stationary, 1 when not or when
                                      an input is missing (with the reason)

The rule (``deep-research/landstats.py``, shared with multiroom-load):
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
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import landstats  # noqa: E402
from landstats import BIN_MS, COV_BOUND, MAX_DEV  # noqa: E402,F401  (the bounds, named here too)

BASELINE_MS = 30_000
RECOVERY_MS = 90_000


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
    s = landstats.summary(landstats.read(run_dir / "land-stats.jsonl"), start, end)
    if s is None:
        raise Missing(f"{run_dir}: no land-stats line between the baseline's start and the recovery's end")
    no_ramp = ramp == 0 and effective == 0
    stationary = landstats.stationary(s) and no_ramp
    out = [f"{run_dir.name}: spawn ramp {ramp} (params), {effective} (server); {BIN_MS // 1000} s bins from the "
           f"baseline's start to the recovery's end ({(end - start) // 1000} s)"]
    out += landstats.lines_table(s)
    out[-1] += f"; spawn ramp {'0 in params and from the server' if no_ramp else 'not 0'}"
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
