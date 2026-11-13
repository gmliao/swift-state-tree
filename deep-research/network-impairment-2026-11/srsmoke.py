#!/usr/bin/env python3
"""The SR smoke's check (design § 4), stdlib only: SR at 10 rooms with its pause fixed at 25 s,
run first, before the 300-room SR-CAL, to show the mechanics under sync-lag tracking (#332).

Usage:
  srsmoke.py <data/<RUN_ID>-SR-r1>     exit 0 and a one-line summary, or exit 1 with each failure

It passes when
- the run is SR at 10 rooms with `SR_PAUSE` 25 (`params.slowReadS`);
- every slow reader (lt-client) paused reading (`readPausedAt` on its client close), sent acks
  while paused (`acksSentWhilePaused` > 0: the precondition of the 4010), got exactly one resync
  in the pause, was closed by the server as a slow consumer (4010) during the pause, and was
  rebuilt by a firstSync after that close, by the end of recovery (design § 7: it reconnects with
  a firstSync; the client reconnects about 1 s after the close, inside the pause, and the new
  connection pauses for what is left of the window);
- no slow reader was closed by the client's stale check during the pause;
- no healthy session (lt-good) got a resync or was closed by the server or the stale check.
It checks the mechanics, not the pause: srpause.py computes SR's pause from the 300-room SR-CAL.
"""
from __future__ import annotations

import json
import pathlib
import sys

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC))
import analysis  # noqa: E402

SMOKE_ROOMS = 10
SMOKE_PAUSE_S = 25
SLOW_INSTANCE = "lt-client"
HEALTHY_INSTANCE = "lt-good"


def failures(run_dir: pathlib.Path) -> tuple[list[str], dict]:
    """What failed (empty: the smoke passed), and what the check saw."""
    out: list[str] = []
    for name in ("run.json", "impairment-timeline.json", "land-lifecycle.jsonl"):
        if not (run_dir / name).exists():
            return [f"{run_dir}: no {name}"], {}
    run = json.loads((run_dir / "run.json").read_text(encoding="utf-8"))
    params = run.get("params") or {}
    if params.get("cell") != "SR":
        out.append(f"{run_dir}: cell {params.get('cell')!r}: the smoke is SR (the 300-room SR-CAL is srpause.py's)")
    if params.get("rooms") != SMOKE_ROOMS:
        out.append(f"{run_dir}: {params.get('rooms')} rooms: the smoke runs at {SMOKE_ROOMS}")
    if params.get("slowReadS") != SMOKE_PAUSE_S:
        out.append(f"{run_dir}: pause {params.get('slowReadS')} s: the smoke fixes SR_PAUSE at {SMOKE_PAUSE_S}")
    try:
        timeline = analysis.read_timeline(run_dir / "impairment-timeline.json")
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as e:
        return out + [f"{run_dir}: unreadable timeline ({e})"], {}
    applied, lifted = timeline.applied_at, timeline.lifted_at
    end = lifted + analysis.RECOVERY_MS
    log = analysis.read_lifecycle(run_dir / "land-lifecycle.jsonl") or {}
    slow = list(analysis.read_samples(run_dir / "samples" / SLOW_INSTANCE))
    healthy = list(analysis.read_samples(run_dir / "samples" / HEALTHY_INSTANCE))
    if not slow:
        return out + [f"{run_dir}: no samples/{SLOW_INSTANCE}/ (the slow readers)"], {}
    match = analysis.match_closes(slow, log)
    try:
        subjects = analysis.outage_sessions(slow, log, timeline, match["sessionsByKey"])
    except ValueError as e:  # a connection's resync lines disagree with its close record
        return out + [f"{run_dir}: {e}"], {}
    target = ((run.get("groups") or {}).get("impaired") or {}).get("target")
    if target is not None and len(subjects) != target:
        out.append(f"{run_dir}: {len(subjects)} slow readers open at the pause, the run has {target}")
    client_close = {}
    for r in sorted((r for r in slow if r.get("r") == "close" and r.get("joined") and r["t"] >= applied), key=lambda r: r["t"]):
        client_close.setdefault(r["key"], r)
    problems: dict[str, list[str]] = {}
    for s in subjects:
        key = s["key"]
        why = problems.setdefault(key, [])
        cc = client_close.get(key) or {}
        if cc.get("readPausedAt") is None:
            why.append("never paused reading")
        if not (cc.get("acksSentWhilePaused") or 0) > 0:
            why.append(f"no acks while paused ({cc.get('acksSentWhilePaused')!r})")
        if len(s["resyncs"]) != 1:
            why.append(f"{len(s['resyncs'])} resyncs, not 1")
        if s.get("serverKind") != "slowConsumer" or s["serverT"] is None or not (applied <= s["serverT"] <= lifted):
            why.append(f"closed by {s.get('serverKind')} at {s['serverT']}, not a 4010 during the pause")
        if cc.get("cause") == "stale" and applied <= cc["t"] <= lifted:
            why.append("closed by the stale check during the pause")
        # Both times are the client's: its close of the connection, then its reconnect's firstSync.
        closed_at = s.get("clientCloseT")
        if s["firstSyncAt"] is None or closed_at is None or not (closed_at <= s["firstSyncAt"] <= end):
            why.append("not rebuilt by a firstSync after its close, by the end of recovery")
    for key, why in sorted(problems.items()):
        if why:
            out.append(f"{run_dir}: slow reader {key}: " + "; ".join(why))
    resynced = sorted({r["k"] for r in healthy if r.get("r") == "resync" and applied <= r["t"] < end})
    closed = sorted({r["key"] for r in healthy if r.get("r") == "close" and r.get("joined") and applied <= r["t"] < end
                     and (r.get("initiator") == "server" or r.get("cause") == "stale")})
    if resynced:
        out.append(f"{run_dir}: {len(resynced)} healthy session(s) resynced ({', '.join(resynced[:5])})")
    if closed:
        out.append(f"{run_dir}: {len(closed)} healthy session(s) closed by the server or the stale check ({', '.join(closed[:5])})")
    to_4010 = [s["serverT"] - applied for s in subjects if s.get("serverKind") == "slowConsumer" and s["serverT"] is not None]
    return out, {"slowReaders": len(subjects), "pauseTo4010Ms": (min(to_4010), max(to_4010)) if to_4010 else None}


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    failed, seen = failures(pathlib.Path(argv[0]))
    if failed:
        for line in failed:
            print(f"srsmoke.py: FAIL: {line}", file=sys.stderr)
        return 1
    lo, hi = seen["pauseTo4010Ms"]
    print(f"srsmoke.py: PASS: {seen['slowReaders']} slow readers: 1 resync each, then 4010 {lo}–{hi} ms into the pause, "
          "rebuilt by a firstSync by the end of recovery; healthy sessions clean")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
