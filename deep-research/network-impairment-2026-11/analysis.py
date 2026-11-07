#!/usr/bin/env python3
"""Reader, segmenter and window metrics for the network impairment runs.

A run's raw data lives in ``data/<run-id>/``:

- ``run.json``: ``meta`` and ``params`` (see README), and ``groups``: for each client instance
  (its samples subdirectory), its group name and the number of connections it targets, e.g.
  ``{"impaired": {"instance": "lt-client", "target": 1200}, "healthy": {...}}``. A group may
  also name ``lands``: then only that instance's connections to those land IDs belong to it, so
  one instance can hold two groups (M's healthy players in mixed rooms and in healthy rooms).
- ``impairment-timeline.json``: written by ws-loadtest's ``scripts/impair.sh``; one ``apply``
  and one ``lift`` entry. P0 runs have them too (applying P0), so every run has the same segments.
- ``samples/<instance>/w<i>.ndjson.gz``: ws-loadtest ``--samples-dir`` output, one per worker.

``ingest`` turns it into ``results/<run-id>.json``: the per-group, per-window series that
``regenerate.py`` reads. Every time is ms since epoch, the base the samples, the timeline's
``wallMsAfter`` and the server's transport profile ``ts`` share.

Segments (design § 5): baseline is the 30 s before the apply, impaired runs from the apply to
the lift, recovery the 90 s after the lift. A sample is assigned by the time its kind names:
an action by its intended send time, a move event by its send time, an update by its arrival.

Stdlib only.
"""
from __future__ import annotations

import argparse
import gzip
import json
import math
import pathlib
import sys
from dataclasses import dataclass, field
from typing import Iterable, Iterator

BASELINE_MS = 30_000
RECOVERY_MS = 90_000
WINDOW_MS = 1_000
# An action answered more than this after its intended send is `late` (the report's threshold).
LATE_MS = 5_000
# A healthy window needs at least this many move events sent, and this share of them seen.
MIN_INPUT_SAMPLES = 50
MIN_SEEN_SHARE = 0.99
MIN_SEND_SHARE = 0.95
RECOVERY_RUN = 5

SEGMENTS = ("baseline", "impaired", "recovery")


# --- reading -------------------------------------------------------------------------------


def read_samples(directory: pathlib.Path) -> Iterator[dict]:
    """Every record of every ``w*.ndjson.gz`` in ``directory``, file by file."""
    for path in sorted(directory.glob("w*.ndjson.gz")):
        with gzip.open(path, "rt", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    yield json.loads(line)


@dataclass(frozen=True)
class Timeline:
    applied_at: int
    lifted_at: int
    profile: str

    @property
    def segments(self) -> dict[str, tuple[int, int]]:
        """Each segment's ``[start, end)`` in ms since epoch."""
        return {
            "baseline": (self.applied_at - BASELINE_MS, self.applied_at),
            "impaired": (self.applied_at, self.lifted_at),
            "recovery": (self.lifted_at, self.lifted_at + RECOVERY_MS),
        }

    def segment_of(self, t: float) -> str | None:
        for name, (start, end) in self.segments.items():
            if start <= t < end:
                return name
        return None


def read_timeline(path: pathlib.Path) -> Timeline:
    """The run's one apply and one lift. The change time is ``wallMsAfter``: both directions'
    ``tc qdisc change`` had returned by then."""
    entries = json.loads(path.read_text())
    applies = [e for e in entries if e["action"] == "apply"]
    lifts = [e for e in entries if e["action"] == "lift"]
    if len(applies) != 1 or len(lifts) != 1:
        raise ValueError(f"{path}: expected one apply and one lift, got {len(applies)} and {len(lifts)}")
    apply, lift = applies[0], lifts[0]
    if lift["wallMsAfter"] <= apply["wallMsAfter"]:
        raise ValueError(f"{path}: the lift is not after the apply")
    return Timeline(int(apply["wallMsAfter"]), int(lift["wallMsAfter"]), apply["profile"])


# --- per-window metrics --------------------------------------------------------------------


def percentile(values: list[float], p: float) -> float | None:
    """Nearest-rank percentile (``p`` in 0..100); ``None`` for no values."""
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, math.ceil(p / 100 * len(ordered)))
    return ordered[rank - 1]


@dataclass
class Window:
    """One group's samples in one 1 s window, by the times § 5 names."""

    start: int
    joined: int = 0
    sends: int = 0
    rtt_ms: list[float] = field(default_factory=list)
    unanswered: int = 0
    late: int = 0
    inputs_sent: int = 0
    inputs_seen: int = 0
    input_ms: list[float] = field(default_factory=list)
    gaps_ms: list[float] = field(default_factory=list)

    def summary(self) -> dict:
        return {
            "start": self.start,
            "joined": self.joined,
            "sends": self.sends,
            "rttP99": percentile(self.rtt_ms, 99),
            "unanswered": self.unanswered,
            "late": self.late,
            "inputsSent": self.inputs_sent,
            "inputsSeen": self.inputs_seen,
            "inputP99": percentile(self.input_ms, 99),
            "gapP99": percentile(self.gaps_ms, 99),
        }


def joined_intervals(records: Iterable[dict]) -> dict[str, list[tuple[float, float]]]:
    """Per connection key, the spans it was joined: from each ``join`` to the next ``close``
    (a reconnect joins again under the same key). A span still open has end ``inf``."""
    events: dict[str, list[tuple[float, str]]] = {}
    for r in records:
        if r["r"] == "join":
            events.setdefault(r["k"], []).append((r["t"], "join"))
        elif r["r"] == "close" and r.get("joined"):
            events.setdefault(r["key"], []).append((r["t"], "close"))
    spans: dict[str, list[tuple[float, float]]] = {}
    for key, evs in events.items():
        evs.sort()
        open_at = None
        for t, kind in evs:
            if kind == "join" and open_at is None:
                open_at = t
            elif kind == "close" and open_at is not None:
                spans.setdefault(key, []).append((open_at, t))
                open_at = None
        if open_at is not None:
            spans.setdefault(key, []).append((open_at, math.inf))
    return spans


def windows(records: list[dict], start: int, end: int, rtt_target_per_s: float | None = None) -> list[Window]:
    """One group's 1 s windows over ``[start, end)``. ``joined`` is the number of connections
    joined for the whole window."""
    count = (end - start) // WINDOW_MS
    out = [Window(start + i * WINDOW_MS) for i in range(count)]

    def slot(t: float) -> Window | None:
        i = int((t - start) // WINDOW_MS)
        return out[i] if 0 <= i < count else None

    for r in records:
        kind = r["r"]
        if kind == "rtt":
            w = slot(r["intendedAt"])
            if w is None:
                continue
            w.sends += 1
            if r["respondedAt"] is None:
                w.unanswered += 1
            else:
                ms = r["respondedAt"] - r["intendedAt"]
                if ms > LATE_MS:
                    w.late += 1
                w.rtt_ms.append(ms)
        elif kind == "input":
            w = slot(r["sentAt"])
            if w is None:
                continue
            w.inputs_sent += 1
            if r["seenAt"] is not None:
                w.inputs_seen += 1
                w.input_ms.append(r["seenAt"] - r["sentAt"])
        elif kind == "update" and r.get("gapMs") is not None:
            w = slot(r["t"])
            if w is not None:
                w.gaps_ms.append(r["gapMs"])

    for spans in joined_intervals(records).values():
        for w in out:
            w_end = w.start + WINDOW_MS
            if any(a <= w.start and b >= w_end for a, b in spans):
                w.joined += 1
    return out


# --- bands, health and recovery ------------------------------------------------------------

BAND_KEYS = ("rttP99", "inputP99", "gapP99")


def band(quiet_runs: list[list[dict]]) -> dict[str, float]:
    """The P0 band (§ 5): for each per-window metric, the largest over the repeats of the p95,
    over that repeat's quiet windows (baseline and impaired segments of P0), of its value."""
    edges: dict[str, float] = {}
    for key in BAND_KEYS:
        per_repeat = []
        for run_windows in quiet_runs:
            values = [w[key] for w in run_windows if w[key] is not None]
            p95 = percentile(values, 95)
            if p95 is not None:
                per_repeat.append(p95)
        if per_repeat:
            edges[key] = max(per_repeat)
    return edges


def health(w: dict, target: int, send_target: float, edges: dict[str, float]) -> str:
    """``healthy``, ``unhealthy`` or ``insufficient`` (§ 5). An insufficient window neither
    passes nor fails; it breaks a run of healthy windows."""
    if w["inputsSent"] < MIN_INPUT_SAMPLES:
        return "insufficient"
    ok = (
        w["joined"] == target
        and w["sends"] >= MIN_SEND_SHARE * send_target
        and w["inputsSeen"] >= MIN_SEEN_SHARE * w["inputsSent"]
        and w["unanswered"] == 0
    )
    for key in BAND_KEYS:
        if key in edges and w[key] is not None and w[key] > edges[key]:
            ok = False
    return "healthy" if ok else "unhealthy"


def recovery_ms(states: list[str], window_starts: list[int], lifted_at: int) -> int | None:
    """From the lift to the start of the first run of ``RECOVERY_RUN`` consecutive healthy
    windows, all inside the recovery segment (``states`` and ``window_starts`` cover it);
    ``None`` when no run fits."""
    run = 0
    for i, state in enumerate(states):
        run = run + 1 if state == "healthy" else 0
        if run == RECOVERY_RUN:
            return window_starts[i - RECOVERY_RUN + 1] - lifted_at
    return None


def in_lands(records: list[dict], lands: set[str]) -> list[dict]:
    """The records of connections joined to one of ``lands`` (a key's land is its join's)."""
    land_of = {r["k"]: r["land"] for r in records if r["r"] == "join"}

    def key(r: dict) -> str | None:
        return r.get("k", r.get("key"))

    return [r for r in records if r["r"] == "phase" or land_of.get(key(r)) in lands]


# --- ingest --------------------------------------------------------------------------------


def ingest(run_dir: pathlib.Path) -> dict:
    """``results/<run-id>.json`` content for one run directory."""
    run = json.loads((run_dir / "run.json").read_text())
    timeline = read_timeline(run_dir / "impairment-timeline.json")
    start = timeline.segments["baseline"][0]
    end = timeline.segments["recovery"][1]
    groups = {}
    for name, group in run["groups"].items():
        records = list(read_samples(run_dir / "samples" / group["instance"]))
        if "lands" in group:
            records = in_lands(records, set(group["lands"]))
        ws = windows(records, start, end)
        groups[name] = {
            "target": group["target"],
            "sendTargetPerS": group.get("sendTargetPerS"),
            "windows": [dict(w.summary(), segment=timeline.segment_of(w.start)) for w in ws],
            "closes": sorted(
                ({"t": r["t"], "key": r["key"], "initiator": r["initiator"], "code": r.get("code"), "cause": r.get("cause")}
                 for r in records if r["r"] == "close" and r.get("joined")),
                key=lambda c: c["t"],
            ),
            "reconnects": [
                {k: r.get(k) for k in ("key", "cause", "closedAt", "outcome", "firstSyncAt")}
                for r in records if r["r"] == "reconnect"
            ],
        }
    return {
        "meta": run["meta"],
        "params": dict(run["params"], profile=timeline.profile),
        "timeline": {"appliedAt": timeline.applied_at, "liftedAt": timeline.lifted_at},
        "groups": groups,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("ingest", help="data/<run-id>/ -> results/<run-id>.json")
    p.add_argument("run_dir", type=pathlib.Path)
    args = parser.parse_args(argv)
    if args.command == "ingest":
        here = pathlib.Path(__file__).parent
        out = here / "results" / f"{args.run_dir.name}.json"
        out.parent.mkdir(exist_ok=True)
        out.write_text(json.dumps(ingest(args.run_dir), indent=1) + "\n")
        print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
