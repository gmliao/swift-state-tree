#!/usr/bin/env python3
"""The slow reader's pause for SR, from the SR calibration run (design § 4), or a refusal
(stdlib only).

  srpause.py <data/<RUN_ID>-SR-CAL>     prints the pause in whole seconds; exit 1 with the reason
                                        when the run can't give one

The pause is the **maximum** time-to-unwritable over the slow-reader players of the calibration
run, plus 30 s (the backlog bound's unwritable timer) plus 10 s, rounded up to whole seconds.

- **The pause starts** at the run's apply (impairment-timeline.json): the slow readers stop
  reading at that offset (`--slow-read`), and the schedule applies profile SR there.
- **The slow readers** are the impaired group's connections, lt-client's (slot 0 of the mixed
  rooms, plan.instances). Their join samples (`samples/lt-client/`) map each server playerID to
  the connection's key, which a reconnect keeps (it joins again under a new playerID).
- **A slow reader's time-to-unwritable** comes from its first backlog close in the lifecycle log
  (`land-lifecycle.jsonl`) between the apply and the lift. A `backlogUnwritable` close fires
  `UNWRITABLE_MS` after the session became unwritable, so its onset is the close minus that. A
  `backlogBytes` close hit the 8 MiB bound first, so its onset is at most the close; that bound is
  used, which can only lengthen the pause. A connection counts once, by its first such close.
- **It refuses** when an input is missing or unreadable; when the run isn't the SR calibration;
  when the run set a send-backlog variable (the 30 s timer is the shipped default's); when any
  player that isn't a slow reader was backlog-closed during the pause (a healthy player closed
  is a finding, not calibration data); when the slow readers that became unwritable aren't
  exactly the run's slow readers (`groups.impaired.target`: fewer means the calibration pause was
  too short for some); or when an onset falls before the apply.
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
SLOW_INSTANCE = "lt-client"


class Refused(ValueError):
    pass


def pause_seconds(run_dir: pathlib.Path) -> tuple[int, dict]:
    """The pause in whole seconds, and what it came from."""
    for name in ("run.json", "impairment-timeline.json", "land-lifecycle.jsonl"):
        if not (run_dir / name).exists():
            raise Refused(f"{run_dir}: no {name}")
    if not analysis.sample_files(run_dir / "samples" / SLOW_INSTANCE):
        raise Refused(f"{run_dir}: no samples/{SLOW_INSTANCE}/ worker files (the slow readers' joins)")
    run = json.loads((run_dir / "run.json").read_text())
    params = run.get("params") or {}
    if params.get("cell") != "SR-CAL":
        raise Refused(f"{run_dir}: not the SR calibration (cell {params.get('cell')!r})")
    target = ((run.get("groups") or {}).get("impaired") or {}).get("target")
    if not target:
        raise Refused(f"{run_dir}: run.json has no slow-reader target (groups.impaired.target)")
    backlog = (run.get("meta") or {}).get("sendBacklogEnv")
    if backlog is None or any(backlog.values()):
        raise Refused(f"{run_dir}: send-backlog settings {backlog}: the unwritable timer is the shipped "
                      f"{UNWRITABLE_MS} ms only with both recorded and unset")
    # The slow readers: lt-client's connections, by the server playerID each join was given.
    key_of = {r["serverPlayer"]: r["k"] for r in analysis.read_samples(run_dir / "samples" / SLOW_INSTANCE)
              if r.get("r") == "join" and r.get("serverPlayer")}
    try:
        timeline = analysis.read_timeline(run_dir / "impairment-timeline.json")
    except (ValueError, KeyError, json.JSONDecodeError) as e:
        raise Refused(f"{run_dir}: unreadable timeline ({e})") from None
    sessions = analysis.read_lifecycle(run_dir / "land-lifecycle.jsonl") or {}
    first: dict[str, int] = {}  # slow reader's connection key -> earliest unwritable onset (epoch ms)
    healthy: list[str] = []
    for s in sessions.values():
        close = s.get("close")
        if not close or close["cause"] not in BACKLOG_CAUSES:
            continue
        if not (timeline.applied_at <= close["t"] <= timeline.lifted_at):
            continue
        onset = close["t"] - UNWRITABLE_MS if close["cause"] == "backlogUnwritable" else close["t"]
        for join in s["joins"]:
            key = key_of.get(join["playerID"])
            if key is None:
                healthy.append(join["playerID"])
            else:
                first[key] = min(first.get(key, onset), onset)
    if healthy:
        raise Refused(f"{run_dir}: {len(healthy)} backlog-closed player(s) not among lt-client's joins "
                      f"({', '.join(sorted(healthy)[:5])}): a healthy player closed, or a slow reader's join sample "
                      "missing; either way not calibration data")
    if not first:
        raise Refused(f"{run_dir}: no slow reader became unwritable during the pause (no backlog close between apply and lift)")
    if len(first) != target:
        raise Refused(f"{run_dir}: {len(first)} slow readers became unwritable during the pause, the run has {target}: "
                      + ("the calibration pause was too short for the rest" if len(first) < target else "more than its slow readers"))
    worst = max(first.values()) - timeline.applied_at
    if min(first.values()) < timeline.applied_at:
        raise Refused(f"{run_dir}: an unwritable onset falls before the apply ({min(first.values()) - timeline.applied_at} ms)")
    seconds = math.ceil(worst / 1000) + MARGIN_S
    return seconds, {"players": len(first), "target": target, "maxTimeToUnwritableMs": worst}  # players: slow readers


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
