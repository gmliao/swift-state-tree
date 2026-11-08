#!/usr/bin/env python3
"""The slow reader's pause for SR, from the SR calibration run (design § 4), or a refusal
(stdlib only).

  srpause.py <data/<RUN_ID>-SR-CAL>     prints the pause in whole seconds; exit 1 with the reason
                                        when the run can't give one

The pause is the **maximum** time-to-unwritable over the slow-reader players of the calibration
run, plus 30 s (the backlog bound's unwritable timer) plus 10 s, rounded up to whole seconds.

- **The pause starts** at the run's apply (impairment-timeline.json): the slow readers stop
  reading at that offset (`--slow-read`), and the schedule applies profile SR there.
- **A slow reader's time-to-unwritable** comes from its first backlog close in the lifecycle log
  (`land-lifecycle.jsonl`) between the apply and the lift. A `backlogUnwritable` close fires
  `UNWRITABLE_MS` after the session became unwritable, so its onset is the close minus that. A
  `backlogBytes` close hit the 8 MiB bound first, so its onset is at most the close; that bound is
  used, which can only lengthen the pause. A player counts once, by its first such close (a
  reconnect can close again).
- **It refuses** when an input is missing or unreadable, when the run isn't the SR calibration,
  when no slow reader became unwritable, when fewer players did than the run's slow readers
  (`groups.impaired.target`: the calibration pause was too short for some), or when an onset
  falls before the apply.
"""
from __future__ import annotations

import json
import math
import pathlib
import sys

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC))
import analysis  # noqa: E402

# The backlog bound's unwritable timer at its shipped default (WS_SEND_BACKLOG_MAX_UNWRITABLE_MS):
# the impairment sweep runs the server's defaults.
UNWRITABLE_MS = 30_000
MARGIN_S = 30 + 10
BACKLOG_CAUSES = ("backlogUnwritable", "backlogBytes")


class Refused(ValueError):
    pass


def pause_seconds(run_dir: pathlib.Path) -> tuple[int, dict]:
    """The pause in whole seconds, and what it came from."""
    for name in ("run.json", "impairment-timeline.json", "land-lifecycle.jsonl"):
        if not (run_dir / name).exists():
            raise Refused(f"{run_dir}: no {name}")
    run = json.loads((run_dir / "run.json").read_text())
    params = run.get("params") or {}
    if params.get("cell") != "SR-CAL":
        raise Refused(f"{run_dir}: not the SR calibration (cell {params.get('cell')!r})")
    target = ((run.get("groups") or {}).get("impaired") or {}).get("target")
    if not target:
        raise Refused(f"{run_dir}: run.json has no slow-reader target (groups.impaired.target)")
    try:
        timeline = analysis.read_timeline(run_dir / "impairment-timeline.json")
    except (ValueError, KeyError, json.JSONDecodeError) as e:
        raise Refused(f"{run_dir}: unreadable timeline ({e})") from None
    sessions = analysis.read_lifecycle(run_dir / "land-lifecycle.jsonl") or {}
    first: dict[str, int] = {}  # player -> earliest unwritable onset (epoch ms)
    for s in sessions.values():
        close = s.get("close")
        if not close or close["cause"] not in BACKLOG_CAUSES:
            continue
        if not (timeline.applied_at <= close["t"] <= timeline.lifted_at):
            continue
        onset = close["t"] - UNWRITABLE_MS if close["cause"] == "backlogUnwritable" else close["t"]
        for join in s["joins"]:
            player = join["playerID"]
            first[player] = min(first.get(player, onset), onset)
    if not first:
        raise Refused(f"{run_dir}: no slow reader became unwritable during the pause (no backlog close between apply and lift)")
    if len(first) < target:
        raise Refused(f"{run_dir}: {len(first)} of {target} slow readers became unwritable during the pause: "
                      "the calibration pause was too short for the rest")
    worst = max(first.values()) - timeline.applied_at
    if min(first.values()) < timeline.applied_at:
        raise Refused(f"{run_dir}: an unwritable onset falls before the apply ({min(first.values()) - timeline.applied_at} ms)")
    seconds = math.ceil(worst / 1000) + MARGIN_S
    return seconds, {"players": len(first), "target": target, "maxTimeToUnwritableMs": worst}


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    try:
        seconds, basis = pause_seconds(pathlib.Path(argv[0]))
    except Refused as e:
        print(f"srpause.py: refused: {e}", file=sys.stderr)
        return 1
    print(f"srpause.py: {basis['players']} of {basis['target']} slow readers; max time-to-unwritable "
          f"{basis['maxTimeToUnwritableMs']} ms; pause = that + {MARGIN_S} s", file=sys.stderr)
    print(seconds)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
