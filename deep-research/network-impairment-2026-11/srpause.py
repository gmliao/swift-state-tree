#!/usr/bin/env python3
"""The slow reader's pause for SR, from the SR calibration run (design § 4), or a refusal
(stdlib only).

  srpause.py <data/<RUN_ID>-SR-CAL>     prints the pause in whole seconds; exit 1 with the reason
                                        when the run can't give one

Under sync-lag tracking (#332, at its defaults: resync at 3 s of lag, 10 s ack timeout), a slow
reader keeps acking its unchanged last sequence every second while its reading is paused, so its
acks stay fresh: the server resyncs it once (about 3 s into the pause), then closes it as a slow
consumer (4010) when the resync's full view has gone unacked for 10 s, about 13-14.5 s in. The
pause is the **maximum** time from the pause to that 4010 over the slow readers, plus 10 s,
rounded up to whole seconds (about 23-24 s).

- **The pause starts** at the run's apply (impairment-timeline.json): the slow readers stop
  reading at that offset (`--slow-read`), and the schedule applies profile SR there.
- **The slow readers** are the impaired group's connections, lt-client's (slot 0 of the mixed
  rooms, plan.instances). Their join samples (`samples/lt-client/`) map each server playerID to
  the connection's key, which a reconnect keeps (it joins again under a new playerID).
- **A slow reader's time:** pause → 4010 is the server's close of its session in the lifecycle
  log (`land-lifecycle.jsonl`, `serverClose` with code 4010), on the server's clock. A connection
  key counts once, by its first close between the apply and the lift; its reconnects (each pauses
  for what is left of the window, gets its own resync and 4010, and reconnects again about 16 s
  later) don't feed the pause.
- **Its resync is counted on the client's side** (`analysis.outage_sessions`, as srsmoke.py and
  regenerate.py count it): the `resync` lines of the connection open at the apply, up to that
  connection's close as the client logged it, which must equal that close record's own `resyncs`
  (a connection without such a record, or a record without the count, is refused).
  It isn't bounded by the server's 4010: a paused reader handles its buffered frames only when
  its connection closes, so its resync line comes just before its own close record and up to a
  second after the server's close (the server sends it about 3 s into the pause: its profile
  counts `syncLagResyncs` there). For the same reason the client's arrival time of a paused
  reader's resync says nothing about when it was sent, and isn't reported.
- **It refuses** when an input is missing or unreadable; when the run isn't the SR calibration;
  when the run set a send-backlog variable (the server's defaults are part of the calibration);
  when any player that isn't a slow reader was server-closed during the pause (a healthy player
  closed is a finding, not calibration data); when a slow reader's close isn't 4010; when a slow
  reader's first close in the pause isn't that of its connection open at the apply; when that
  connection didn't get exactly one resync, has no close record with a resync count, or its
  resync lines and its close record disagree;
  when a slow reader sent no acks while its reading was paused (the precondition the 4010 rests
  on: without them its acks go stale and the close is 4011); when the slow readers closed aren't
  exactly the run's slow readers (`groups.impaired.target`); or when a slow reader has a resync
  before the apply. 4008 onsets are not used.
"""
from __future__ import annotations

import json
import math
import pathlib
import sys

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC))
import analysis  # noqa: E402

MARGIN_S = 10
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
        raise Refused(f"{run_dir}: send-backlog settings {backlog}: the calibration runs the server's defaults "
                      "only with both recorded and unset")
    records = list(analysis.read_samples(run_dir / "samples" / SLOW_INSTANCE))
    # The slow readers: lt-client's connections, by the server playerID each join was given.
    key_of = {r["serverPlayer"]: r["k"] for r in records if r.get("r") == "join" and r.get("serverPlayer")}
    try:
        timeline = analysis.read_timeline(run_dir / "impairment-timeline.json")
    except (ValueError, KeyError, json.JSONDecodeError) as e:
        raise Refused(f"{run_dir}: unreadable timeline ({e})") from None
    applied, lifted = timeline.applied_at, timeline.lifted_at
    sessions = analysis.read_lifecycle(run_dir / "land-lifecycle.jsonl") or {}
    closes: dict[str, dict] = {}  # slow reader's key -> its first server close between apply and lift
    healthy: list[str] = []
    for s in sessions.values():
        close = s.get("close")
        if not close or close["cause"] not in analysis.SERVER_DECIDED:
            continue
        if not (applied <= close["t"] <= lifted):
            continue
        for join in s["joins"]:
            key = key_of.get(join["playerID"])
            if key is None:
                healthy.append(join["playerID"])
            elif key not in closes or close["t"] < closes[key]["t"]:
                closes[key] = close
    if healthy:
        raise Refused(f"{run_dir}: {len(healthy)} server-closed player(s) not among lt-client's joins "
                      f"({', '.join(sorted(healthy)[:5])}): a healthy player closed, or a slow reader's join sample "
                      "missing; either way not calibration data")
    if not closes:
        raise Refused(f"{run_dir}: no slow reader was closed during the pause (no server close between apply and lift)")
    if len(closes) != target:
        raise Refused(f"{run_dir}: {len(closes)} slow readers were closed during the pause, the run has {target}: "
                      + ("the calibration pause was too short for the rest" if len(closes) < target else "more than its slow readers"))
    not_4010 = sorted(k for k, c in closes.items() if c["kind"] != "slowConsumer")
    if not_4010:
        kinds = sorted({closes[k]["kind"] for k in not_4010})
        raise Refused(f"{run_dir}: {len(not_4010)} slow reader(s) closed by {', '.join(kinds)}, not a slow-consumer "
                      f"close (4010) ({', '.join(not_4010[:5])})")
    resyncs = analysis.resync_times(records)
    # Each slow reader's connection open at the apply, its resyncs counted on the client's side
    # (client arrivals within the client's own joined span, never against a server-side time).
    try:
        match = analysis.match_closes(records, sessions)
        subjects = {s["key"]: s for s in analysis.outage_sessions(records, sessions, timeline, match["sessionsByKey"])}
    except ValueError as e:  # its resync lines disagree with its close record
        raise Refused(f"{run_dir}: {e}") from None
    to_close: dict[str, float] = {}
    for key, close in sorted(closes.items()):
        if any(t < applied for t in resyncs.get(key, [])):
            raise Refused(f"{run_dir}: {key}: a resync falls before the apply")
        s = subjects.get(key)
        if s is None or s["serverT"] != close["t"]:
            raise Refused(f"{run_dir}: {key}: its first close in the pause (at {close['t']}) isn't its connection open "
                          f"at the apply's ({s and s['serverT']!r})")
        if s["recordedResyncs"] is None:
            raise Refused(f"{run_dir}: {key}: its connection open at the apply has no client close record with a resync "
                          "count (no close ending its span, or one without `resyncs`): the count can't be cross-checked")
        if len(s["resyncs"]) != 1:
            raise Refused(f"{run_dir}: {key}: {len(s['resyncs'])} resyncs on its connection open at the apply "
                          "(client side, up to its close), not exactly 1")
        sent = s["acksSentWhilePaused"]
        if not sent:
            raise Refused(f"{run_dir}: {key}: sent no acks while its reading was paused ({sent!r}): "
                          "the 4010 rests on fresh acks during the pause")
        to_close[key] = close["t"] - applied
    worst = max(to_close.values())
    seconds = math.ceil(worst / 1000) + MARGIN_S
    return seconds, {"players": len(closes), "target": target, "maxPauseTo4010Ms": worst,
                     "minPauseTo4010Ms": min(to_close.values())}


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    try:
        seconds, basis = pause_seconds(pathlib.Path(argv[0]))
    except Refused as e:
        print(f"srpause.py: refused: {e}", file=sys.stderr)
        return 1
    print(f"srpause.py: {basis['players']} of {basis['target']} slow readers closed with 4010, one resync each; "
          f"pause → 4010 {basis['minPauseTo4010Ms']}–{basis['maxPauseTo4010Ms']} ms; "
          f"pause = max pause → 4010 + {MARGIN_S} s", file=sys.stderr)
    print(seconds)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
