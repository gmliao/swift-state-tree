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
- ``profile.jsonl``: the server's transport profile (``TRANSPORT_PROFILE_JSONL_PATH``).
- ``system-metrics.json``: the server process's samples (``monitoring/system-metrics.json``).
- ``sockstat.jsonl``: ws-loadtest's ``sockstat-main.js`` samples; namespace ``""`` is the server's.
- ``convergence.json``: ws-loadtest's ``converge-main.js`` report, the convergence check after recovery.

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
from collections import Counter
from dataclasses import dataclass, field
from typing import Iterable, Iterator

BASELINE_MS = 30_000
RECOVERY_MS = 90_000
WINDOW_MS = 1_000
# An action answered more than this after its intended send is `late` (the report's threshold).
LATE_MS = 5_000
# § 2's per-window client-bound gate: a window is client-bound when a worker's event loop was
# busy for more than this share of a span overlapping it (`loop` samples).
CLIENT_BOUND_ELU = 0.9
# § 2's run-wide reference, for the gate's validation: the worst worker's loop-delay p99.
LOOP_DELAY_P99_LIMIT_MS = 20
# A worker's loop spans must cover the run with no gap over this (a stopped sampler).
LOOP_GAP_MS = 2_000
# More than this share of a segment's windows client-bound leaves too little to judge.
CLIENT_BOUND_MAX_SHARE = 0.2
# A healthy window needs at least this many move events sent, and this share of them seen.
MIN_INPUT_SAMPLES = 50
MIN_SEEN_SHARE = 0.99
MIN_SEND_SHARE = 0.95
RECOVERY_RUN = 5
# Per-session recovery looks at the last this-many ms of the recovery segment (§ 5).
SESSION_WINDOW_MS = 10_000

SEGMENTS = ("baseline", "impaired", "recovery")


# --- reading -------------------------------------------------------------------------------


def sample_files(directory: pathlib.Path) -> list[pathlib.Path]:
    """The worker files of one client instance. An empty list (a wrong instance name, a lost
    directory) is a missing input, never zero records (``ingest`` records the count)."""
    return sorted(directory.glob("w*.ndjson.gz"))


def read_samples(directory: pathlib.Path) -> Iterator[dict]:
    """Every record of every ``w*.ndjson.gz`` in ``directory``, file by file. A ``loop`` record
    gets ``worker``, its file's name: one file is one worker."""
    for path in sample_files(directory):
        worker = path.name.split(".", 1)[0]
        with gzip.open(path, "rt", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    r = json.loads(line)
                    if r["r"] == "loop":
                        r["worker"] = worker
                    yield r


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


def histogram(values: list[float]) -> dict[str, int]:
    """Counts per whole millisecond (rounded), keyed by its decimal string (JSON keys)."""
    return {str(k): v for k, v in sorted(Counter(round(x) for x in values).items())}


def hist_percentile(hists: Iterable[dict[str, int]], p: float) -> float | None:
    """Nearest-rank percentile of the pooled histograms; ``None`` when they are empty."""
    pooled: Counter = Counter()
    for h in hists:
        for k, v in h.items():
            pooled[int(k)] += v
    total = sum(pooled.values())
    if total == 0:
        return None
    rank = max(1, math.ceil(p / 100 * total))
    seen = 0
    for value in sorted(pooled):
        seen += pooled[value]
        if seen >= rank:
            return value
    return None


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
    send_lag_ms: list[float] = field(default_factory=list)
    client_bound: bool = False

    def summary(self) -> dict:
        """The window's values, with 1 ms histograms of its move-event latencies and update
        gaps, so a segment's pooled percentiles can be computed exactly from the windows."""
        return {
            "inputHist": histogram(self.input_ms),
            "gapHist": histogram(self.gaps_ms),
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
            "sendLagP99": percentile(self.send_lag_ms, 99),
            "clientBound": self.client_bound,
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


def windows(records: list[dict], start: int, end: int, rtt_target_per_s: float | None = None,
            run_end: float | None = None) -> list[Window]:
    """One group's 1 s windows over ``[start, end)``, the last partial window dropped. ``joined``
    is the number of connections joined for the whole window. An action counts in ``sends`` by
    its actual send time (``sentAt``, § 5's sendsAchieved), and in the RTT, ``unanswered`` and
    ``late`` by its intended send time, the RTT's origin. An action still unanswered because its
    phase ended (``end: "phaseEnd"``) within ``LATE_MS`` of ``run_end`` isn't counted unanswered:
    its answer had no time to arrive before the load test stopped."""
    count = (end - start) // WINDOW_MS
    out = [Window(start + i * WINDOW_MS) for i in range(count)]

    def slot(t: float) -> Window | None:
        i = int((t - start) // WINDOW_MS)
        return out[i] if 0 <= i < count else None

    for r in records:
        kind = r["r"]
        if kind == "rtt":
            sent = slot(r["sentAt"]) if r.get("sentAt") is not None else None
            if sent is not None:
                sent.sends += 1
                sent.send_lag_ms.append(r["sentAt"] - r["intendedAt"])
            w = slot(r["intendedAt"])
            if w is None:
                continue
            if r["respondedAt"] is None:
                if not (run_end is not None and r.get("end") == "phaseEnd" and r["intendedAt"] >= run_end - LATE_MS):
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

    # Client-bound (§ 2): a worker's loop span overlapping the window was busy over the gate.
    for r in records:
        if r["r"] == "loop" and r["elu"] > CLIENT_BOUND_ELU:
            for w in out:
                if r["from"] < w.start + WINDOW_MS and r["to"] > w.start:
                    w.client_bound = True

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
            values = [w[key] for w in run_windows if w[key] is not None and not w.get("clientBound")]
            p95 = percentile(values, 95)
            if p95 is not None:
                per_repeat.append(p95)
        if per_repeat:
            edges[key] = max(per_repeat)
    return edges


def health(w: dict, target: int, send_target: float, edges: dict[str, float]) -> str:
    """``healthy``, ``unhealthy`` or ``insufficient`` (§ 5). An insufficient window neither
    passes nor fails; it breaks a run of healthy windows. A client-bound window (§ 2) is
    insufficient: its latency isn't read as the server's."""
    if w["inputsSent"] < MIN_INPUT_SAMPLES or w.get("clientBound"):
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

    # A worker's loop records belong to every group its connections are in.
    return [r for r in records if r["r"] in ("phase", "loop") or land_of.get(key(r)) in lands]


# --- per session ----------------------------------------------------------------------------


def sessions(records: list[dict], timeline: Timeline) -> dict[str, dict]:
    """Per connection key, what per-session recovery (§ 5) needs: whether it closed, whether a
    reconnect rebuilt it with a firstSync, whether it is joined at the end of the recovery
    segment, its update-gap p99 over the segment's last 10 s, and (for the P0 band) its gap p99
    in every 10 s window of the quiet segments (baseline and impaired)."""
    end = timeline.segments["recovery"][1]
    last = (end - SESSION_WINDOW_MS, end)
    quiet_start = timeline.segments["baseline"][0]
    quiet_end = timeline.segments["impaired"][1]
    quiet_slots = (quiet_end - quiet_start) // SESSION_WINDOW_MS

    gaps: dict[str, list[tuple[float, float]]] = {}
    closes: Counter = Counter()
    reconnects: dict[str, list[dict]] = {}
    for r in records:
        if r["r"] == "update" and r.get("gapMs") is not None:
            gaps.setdefault(r["k"], []).append((r["t"], r["gapMs"]))
        elif r["r"] == "close" and r.get("joined"):
            closes[r["key"]] += 1
        elif r["r"] == "reconnect" and (r.get("closedAt") is None or r["closedAt"] < end):
            # A reconnect from a close after the recovery segment (a teardown) isn't a rebuild.
            reconnects.setdefault(r["key"], []).append(r)
    spans = joined_intervals(records)

    out = {}
    for key, key_spans in spans.items():
        key_gaps = gaps.get(key, [])
        quiet = []
        for i in range(quiet_slots):
            a = quiet_start + i * SESSION_WINDOW_MS
            values = [g for t, g in key_gaps if a <= t < a + SESSION_WINDOW_MS]
            if values:
                quiet.append(percentile(values, 99))
        recs = reconnects.get(key, [])
        out[key] = {
            "closes": closes[key],
            "reconnected": bool(recs),
            "rebuilt": bool(recs) and recs[-1].get("outcome") == "recovered" and recs[-1].get("firstSyncAt") is not None,
            "openAtEnd": any(a <= last[0] and b >= end for a, b in key_spans),
            "lastGapP99": percentile([g for t, g in key_gaps if last[0] <= t < last[1]], 99),
            "quietGapP99s": quiet,
        }
    return out


def session_recovered(session: dict, band_edge: float | None) -> bool:
    """§ 5: open at the end of recovery, rebuilt by a firstSync if it reconnected, and its last
    10 s update-gap p99 within the per-session band. Without a band (no P0 control) no session
    recovers: the check can't be made, so it fails."""
    if not session["openAtEnd"]:
        return False
    if session["reconnected"] and not session["rebuilt"]:
        return False
    if session["lastGapP99"] is None:
        return False
    return band_edge is not None and session["lastGapP99"] <= band_edge


def session_band(p0_sessions: list[dict[str, dict]]) -> float | None:
    """The per-session band's upper edge: the largest 10 s gap p99 of any session in any quiet
    window of the given P0 repeats."""
    values = [v for repeat in p0_sessions for s in repeat.values() for v in s["quietGapP99s"]]
    return max(values) if values else None


# --- server profile ----------------------------------------------------------------------------

# Server-side causes the server decided (§ 7 criterion 2): each needs a client close. `error` is one:
# the server closes on it. The others, `clientClose` and `connectionLost`, are the server observing
# a close the client or the network made.
SERVER_DECIDED = {"pongTimeout", "backlogBytes", "backlogUnwritable", "serverClose", "error"}


def read_lifecycle(path: pathlib.Path) -> dict[str, dict] | None:
    """Per ``sessionID``, from the lifecycle log: its ``joins`` (``playerID``, ``landID``,
    ``instance``, ``t``) and its ``close`` (``cause``, ``code``, ``t``) or ``None``. The lines
    pair by ``sessionID`` in either order; ``None`` without the file."""
    if not path.exists():
        return None
    out: dict[str, dict] = {}
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        r = json.loads(line)
        if r["event"] not in ("sessionJoined", "sessionClosed"):
            continue
        s = out.setdefault(r["sessionID"], {"joins": [], "close": None})
        if r["event"] == "sessionJoined":
            s["joins"].append({"playerID": r["playerID"], "landID": r["landID"],
                               "instance": r.get("instance"), "t": r["wallMs"]})
        elif s["close"] is None:
            s["close"] = {"cause": r["cause"], "code": r.get("code"), "t": r["wallMs"]}
    return out


def _session_of_join(join: dict, by_player: dict[str, list[tuple[int, str, str]]]) -> str | None:
    """The server session a client ``join`` sample was: the same ``serverPlayer`` in the same land,
    the server's join closest in time if the player joined more than once."""
    player = join.get("serverPlayer")
    if player is None:
        return None
    land = join["land"]
    candidates = [(abs(t - join["t"]), sid) for t, sid, land_id in by_player.get(player, [])
                  if land_id == land or land_id.endswith(":" + land)]
    return min(candidates)[1] if candidates else None


def match_closes(records: list[dict], log: dict[str, dict], start: float = -math.inf, end: float = math.inf) -> dict:
    """§ 7 criterion 2 for one group: each client close (of a joined connection) with its
    session's server cause, the sessions those closes matched, and the joins that couldn't be
    mapped (no ``serverPlayer``, or no ``sessionJoined`` for it): any of those fails the group.
    The server-decided closes no client close matched are found per run, over the whole log
    (``server_only``), so a session no join mapped is still checked.

    A close belongs to the connection's latest join before it; a join maps to its server session by
    ``serverPlayer`` (the playerID of the server's JoinResponse) and land. Only closes in
    ``[start, end)`` count, like the server's: a teardown close after the run matches nothing.

    ``duringJoin`` counts the closes in ``[start, end)`` of connections that hadn't joined, by
    initiator, and ``duringJoinServer`` the server-initiated ones (``t``, ``code``). They have no
    join sample and the server's line no player, so they pair per run by code and time
    (``pair_by_code``) with the server-decided closes no client close matched (``server_only``):
    a session that never joined, or one whose JoinResponse crossed the close.

    The join failure counts (no ``serverPlayer``, no ``sessionJoined``) cover joins before ``end``:
    a teardown join after the run fails nothing, and earlier joins still identify connections."""
    by_player: dict[str, list[tuple[int, str, str]]] = {}
    for sid, s in log.items():
        for j in s["joins"]:
            by_player.setdefault(j["playerID"], []).append((j["t"], sid, j["landID"]))
    joins: dict[str, list[tuple[float, str | None]]] = {}
    without_player = unmapped = 0
    for r in records:
        if r["r"] == "join":
            sid = _session_of_join(r, by_player)
            if r["t"] < end and r.get("serverPlayer") is None:
                without_player += 1
            elif r["t"] < end and sid is None:
                unmapped += 1
            joins.setdefault(r["k"], []).append((r["t"], sid))
    closes, matched = [], set()
    in_run = [r for r in records if r["r"] == "close" and start <= r["t"] < end]
    during_join = Counter(r.get("initiator", "unknown") for r in in_run if not r.get("joined"))
    for r in sorted((r for r in in_run if r.get("joined")), key=lambda r: r["t"]):
        before = [sid for t, sid in sorted(joins.get(r["key"], []), key=lambda j: j[0]) if t <= r["t"]]
        sid = before[-1] if before else None
        server_close = log[sid]["close"] if sid is not None else None
        if server_close is not None:
            matched.add(sid)
        closes.append({"key": r["key"], "t": r["t"], "code": r.get("code"), "cause": r.get("cause"), "sessionID": sid,
                       "serverCause": server_close["cause"] if server_close else None,
                       "serverCode": server_close["code"] if server_close else None,
                       "serverT": server_close["t"] if server_close else None})
    return {"closes": closes, "unmatchedClient": sum(1 for c in closes if c["serverCause"] is None),
            "matchedSessions": sorted(matched), "joinsWithoutServerPlayer": without_player,
            "unmappedJoins": unmapped,
            "duringJoin": dict(during_join),
            "duringJoinServer": sorted(({"t": r["t"], "code": r.get("code")} for r in in_run
                                        if not r.get("joined") and r.get("initiator") == "server"),
                                       key=lambda c: c["t"]),
            "sessionsByKey": {k: sorted(js, key=lambda j: j[0]) for k, js in joins.items()}}


def outage_sessions(records: list[dict], log: dict[str, dict], timeline: Timeline,
                    sessions_by_key: dict[str, list[tuple[float, str | None]]]) -> list[dict]:
    """The sessions a group had open at the apply, the subjects of BO75's and SR's per-profile
    criteria (§ 7): per connection key joined across the apply, its server session (the latest
    join before the apply), that session's server-side close cause and time, and the first
    firstSync of a recovered reconnect after the apply."""
    applied = timeline.applied_at
    first_sync: dict[str, float] = {}
    for r in records:
        if r["r"] == "reconnect" and r.get("outcome") == "recovered" and r.get("firstSyncAt") is not None \
                and r["firstSyncAt"] >= applied:
            first_sync[r["key"]] = min(first_sync.get(r["key"], math.inf), r["firstSyncAt"])
    out = []
    for key, spans in sorted(joined_intervals(records).items()):
        if not any(a <= applied < b for a, b in spans):
            continue
        before = [sid for t, sid in sessions_by_key.get(key, []) if t <= applied]
        sid = before[-1] if before else None
        close = log[sid]["close"] if sid is not None and sid in log else None
        out.append({"key": key, "sessionID": sid,
                    "serverCause": close["cause"] if close else None, "serverT": close["t"] if close else None,
                    "firstSyncAt": first_sync.get(key)})
    return out


def unjoined_server_closes(log: dict[str, dict], start: int, end: int) -> list[dict]:
    """The server-decided closes in ``[start, end)`` of sessions that never joined: the server's
    side of the closes during a join."""
    return sorted(
        ({"sessionID": sid, "cause": s["close"]["cause"], "code": s["close"]["code"], "t": s["close"]["t"]}
         for sid, s in log.items()
         if not s["joins"] and s["close"] is not None and s["close"]["cause"] in SERVER_DECIDED
         and start <= s["close"]["t"] < end),
        key=lambda c: (c["t"], c["sessionID"]),
    )


# A close during a join and its server line: the close frame's bound plus the client's detection.
JOIN_CLOSE_TOLERANCE_MS = 5_000


def pair_by_code(client: list[dict], server: list[dict], tolerance_ms: float = JOIN_CLOSE_TOLERANCE_MS) -> dict:
    """One-to-one pairs of client and server closes with the same code, at most ``tolerance_ms``
    apart, in time order (greedy per code, which pairs the most for one tolerance). Returns the
    pair count, the leftovers on each side, and ``ambiguous``: client closes with more than one
    server candidate in tolerance, which a per-connection key would be needed to tell apart."""
    paired = ambiguous = 0
    left_client: list[dict] = []
    left_server: list[dict] = []
    for code in sorted({str(c["code"]) for c in client} | {str(s["code"]) for s in server}):
        cs = sorted((c for c in client if str(c["code"]) == code), key=lambda c: c["t"])
        ss = sorted((s for s in server if str(s["code"]) == code), key=lambda s: s["t"])
        ambiguous += sum(1 for c in cs if sum(1 for s in ss if abs(s["t"] - c["t"]) <= tolerance_ms) > 1)
        i = j = 0
        while i < len(cs) and j < len(ss):
            if abs(cs[i]["t"] - ss[j]["t"]) <= tolerance_ms:
                paired += 1
                i += 1
                j += 1
            elif cs[i]["t"] < ss[j]["t"]:
                left_client.append(cs[i])
                i += 1
            else:
                left_server.append(ss[j])
                j += 1
        left_client += cs[i:]
        left_server += ss[j:]
    return {"paired": paired, "client": left_client, "server": left_server, "ambiguous": ambiguous}


def server_only(log: dict[str, dict], matched: set[str], start: int, end: int) -> list[dict]:
    """Every server-decided close in ``[start, end)`` that no client close matched, in any group:
    a half-open session, a lost close, or a session no client join maps to."""
    return sorted(
        ({"sessionID": sid, "cause": s["close"]["cause"], "code": s["close"]["code"], "t": s["close"]["t"]}
         for sid, s in log.items()
         if sid not in matched and s["close"] is not None and s["close"]["cause"] in SERVER_DECIDED
         and start <= s["close"]["t"] < end),
        key=lambda c: (c["t"], c["sessionID"]),
    )


PROFILE_SUMS = ("pongTimeoutCloses", "sendBacklogCloses", "closeFrameTimeouts", "sendUnwritableEpisodes")
PROFILE_MAXES = ("sendBufferedBytesMax", "sendUnwritableSessions", "sendUnwritableLongestMs")


def read_profile(path: pathlib.Path, start: int, end: int) -> dict | None:
    """The transport profile's counters over ``[start, end)`` by each line's ``ts``: the sums
    of the per-window counts and the largest per-window maxima, and ``seen``: the counter keys
    present in at least one line in range (a build without a counter must not read as 0).
    ``None`` without a profile."""
    if not path.exists():
        return None
    sums = {k: 0 for k in PROFILE_SUMS}
    maxes = {k: 0 for k in PROFILE_MAXES}
    lines = 0
    seen: set[str] = set()
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        obj = json.loads(line)
        if not start <= obj.get("ts", -1) < end:
            continue
        lines += 1
        counters = obj.get("counters", {})
        seen.update(k for k in (*PROFILE_SUMS, *PROFILE_MAXES) if counters.get(k) is not None)
        for k in PROFILE_SUMS:
            sums[k] += counters.get(k, 0) or 0
        for k in PROFILE_MAXES:
            maxes[k] = max(maxes[k], counters.get(k, 0) or 0)
    return dict(sums, **maxes, windows=lines, seen=sorted(seen))


# --- memory ------------------------------------------------------------------------------

LEAK_WINDOW_MS = 30_000
# The leak window's RSS samples: the first and last within 2 s of its edges, no gap over 5 s.
LEAK_EDGE_MS = 2_000
LEAK_GAP_MS = 5_000
# § 7: the RSS slope over the last 30 s of recovery may exceed P0's by at most this, MiB/s.
LEAK_SLOPE_MARGIN = 1.0


def slope_per_s(points: list[tuple[float, float]]) -> float | None:
    """Least-squares slope of ``(t ms, value)`` points, per second; ``None`` under 2 points."""
    if len(points) < 2:
        return None
    n = len(points)
    mt = sum(t for t, _ in points) / n
    mv = sum(v for _, v in points) / n
    den = sum((t - mt) ** 2 for t, _ in points)
    if den == 0:
        return None
    return sum((t - mt) * (v - mv) for t, v in points) / den * 1000


def read_memory(run_dir: pathlib.Path, timeline: Timeline) -> dict | None:
    """Per segment, the server's peak RSS (MiB), the host's peak TCP buffer memory (pages) and
    the server namespace's peak summed Send-Q over all non-listening sockets (bytes); and the
    RSS least-squares slope over the last 30 s of recovery, with the RSS at its end."""
    system_path = run_dir / "system-metrics.json"
    sockstat_path = run_dir / "sockstat.jsonl"
    if not system_path.exists() and not sockstat_path.exists():
        return None
    out: dict = {seg: {"rssPeakMb": None, "hostTcpMemPeakPages": None, "serverSendQPeakBytes": None} for seg in SEGMENTS}

    def bump(seg: str | None, key: str, value: float) -> None:
        if seg is not None and (out[seg][key] is None or value > out[seg][key]):
            out[seg][key] = value

    rss: list[tuple[float, float]] = []
    if system_path.exists():
        try:
            system = json.loads(system_path.read_text())
        except json.JSONDecodeError as error:
            # Two collectors writing one file (two client instances) leave it unreadable: say so.
            raise ValueError(f"{system_path} is not valid JSON ({error}); was it written by more than one collector?") from error
        for sample in system.get("system", []):
            t = sample.get("tsMs", sample.get("ts", 0) * 1000)
            rss.append((t, sample["rssMb"]))
            bump(timeline.segment_of(t), "rssPeakMb", sample["rssMb"])
    if sockstat_path.exists():
        for line in sockstat_path.read_text().splitlines():
            if not line.strip():
                continue
            sample = json.loads(line)
            seg = timeline.segment_of(sample["t"])
            bump(seg, "hostTcpMemPeakPages", sample["hostTcpMemPages"])
            for ns in sample.get("namespaces", []):
                if ns["netns"] == "":
                    send_q = ns["established"]["sendQBytes"] + sum(q["sendQBytes"] for q in ns["otherStates"].values())
                    bump(seg, "serverSendQPeakBytes", send_q)
    end = timeline.segments["recovery"][1]
    tail = sorted((t, v) for t, v in rss if end - LEAK_WINDOW_MS <= t < end)
    # The slope needs the whole window: a lost tail of the recording must not pass.
    covered = (bool(tail) and tail[0][0] - (end - LEAK_WINDOW_MS) <= LEAK_EDGE_MS and end - tail[-1][0] <= LEAK_EDGE_MS
               and all(b[0] - a_[0] <= LEAK_GAP_MS for a_, b in zip(tail, tail[1:])))
    out["rssSlopeLast30sMbPerS"] = slope_per_s(tail) if covered else None
    out["rssAtEndMb"] = tail[-1][1] if tail else None
    return out


# --- isolation -----------------------------------------------------------------------------


def pooled(windows_: list[dict], hist_key: str, p: float = 99) -> float | None:
    return hist_percentile((w[hist_key] for w in windows_), p)


def segment_band(quiet_runs: list[list[dict]], length: int, hist_key: str) -> float | None:
    """§ 7's isolation band: the largest, over the P0 repeats, of the pooled p99 over every run
    of ``length`` consecutive quiet windows (every 1 s offset)."""
    best = None
    for ws in quiet_runs:
        for i in range(0, len(ws) - length + 1):
            v = pooled(ws[i:i + length], hist_key)
            if v is not None and (best is None or v > best):
                best = v
    return best


def loop_summary(records: list[dict], start: int, end: int, workers: list[str]) -> dict:
    """The ``loop`` spans overlapping ``[start, end)``: how many, each worker's largest ELU, and
    ``uncovered``: each of ``workers`` (every worker file) whose spans leave a gap over
    ``LOOP_GAP_MS`` in ``[start, end)``, with the gap. A window no span covers would read as not
    client-bound, so a stopped sampler is a missing input, not a quiet worker."""
    spans = [r for r in records if r["r"] == "loop" and r["from"] < end and r["to"] > start]
    worst: dict[str, float] = {}
    for r in spans:
        worst[r["worker"]] = max(worst.get(r["worker"], 0.0), r["elu"])
    uncovered: dict[str, str] = {}
    for w in workers:
        covered_to, gap = start, None
        for r in sorted((r for r in spans if r["worker"] == w), key=lambda r: r["from"]):
            if r["from"] - covered_to > LOOP_GAP_MS and gap is None:
                gap = (covered_to, r["from"])
            covered_to = max(covered_to, r["to"])
        if gap is None and end - covered_to > LOOP_GAP_MS:
            gap = (covered_to, end)
        if gap is not None:
            uncovered[w] = f"gap {gap[1] - gap[0]} ms from {gap[0] - start} ms"
    return {"spans": len(spans), "maxEluByWorker": dict(sorted(worst.items())), "uncovered": uncovered}


# --- ingest --------------------------------------------------------------------------------


def ingest(run_dir: pathlib.Path) -> dict:
    """``results/<run-id>.json`` content for one run directory."""
    run = json.loads((run_dir / "run.json").read_text())
    timeline = read_timeline(run_dir / "impairment-timeline.json")
    start = timeline.segments["baseline"][0]
    end = timeline.segments["recovery"][1]
    log = read_lifecycle(run_dir / "land-lifecycle.jsonl")
    groups = {}
    for name, group in run["groups"].items():
        files = sample_files(run_dir / "samples" / group["instance"])
        records = list(read_samples(run_dir / "samples" / group["instance"]))
        if "lands" in group:
            records = in_lands(records, set(group["lands"]))
        # Each segment's windows from its own start, so none straddles the apply or the lift.
        ws = [(seg, w) for seg, (s, e) in timeline.segments.items() for w in windows(records, s, e, run_end=end)]
        matches = match_closes(records, log, start, end) if log is not None else None
        outage = outage_sessions(records, log, timeline, matches["sessionsByKey"]) if matches is not None else None
        groups[name] = {
            # What a reader checks before trusting the group: its worker files, and its distinct
            # connection keys against `target` (a lost worker file shrinks the population).
            "manifest": {"files": len(files), "joinKeys": len({r["k"] for r in records if r["r"] == "join"})},
            # The client-bound gate's inputs (§ 2): each worker's largest span ELU in the run.
            "loop": loop_summary(records, start, end, [p.name.split(".", 1)[0] for p in files]),
            "loopDelayP99Ms": group.get("loopDelayP99Ms"),
            "sessions": sessions(records, timeline),
            "target": group["target"],
            "sendTargetPerS": group.get("sendTargetPerS"),
            "windows": [dict(w.summary(), segment=seg) for seg, w in ws],
            "closes": sorted(
                ({"t": r["t"], "key": r["key"], "initiator": r["initiator"], "code": r.get("code"),
                  "cause": r.get("cause"), "slowReader": bool(r.get("slowReader"))}
                 for r in records if r["r"] == "close" and r.get("joined") and start <= r["t"] < end),
                key=lambda c: c["t"],
            ),
            "closeMatch": matches,
            "outageSessions": outage,
            "reconnects": [
                {k: r.get(k) for k in ("key", "cause", "closedAt", "outcome", "firstSyncAt")}
                for r in records if r["r"] == "reconnect" and start <= (r.get("closedAt") or r.get("firstSyncAt") or start) < end
            ],
        }
    matched = {sid for g in groups.values() if g["closeMatch"] for sid in g["closeMatch"]["matchedSessions"]}
    return {
        "meta": run["meta"],
        "serverOnly": server_only(log, matched, start, end) if log is not None else None,
        "unjoinedServerCloses": unjoined_server_closes(log, start, end) if log is not None else None,
        "expectedProfileWindows": (end - start) // WINDOW_MS,
        "params": dict(run["params"], profile=timeline.profile),
        "timeline": {"appliedAt": timeline.applied_at, "liftedAt": timeline.lifted_at},
        "groups": groups,
        "server": read_profile(run_dir / "profile.jsonl", start, end),
        "sessionCloseCauses": (
            dict(Counter(s["close"]["cause"] for s in log.values()
                         if s["close"] is not None and start <= s["close"]["t"] < end))
            if log is not None else None
        ),
        "memory": read_memory(run_dir, timeline),
        "convergence": read_convergence(run_dir / "convergence.json"),
    }


def read_convergence(path: pathlib.Path) -> dict | None:
    """The convergence check's report (ws-loadtest ``converge-main.js``, design § 6), reduced to
    its totals and the lands that didn't converge; ``None`` without the file (a missing input)."""
    if not path.exists():
        return None
    report = json.loads(path.read_text())
    return {
        "totals": report["totals"],
        "durationMs": report["endedAt"] - report["startedAt"],
        "notConverged": [
            {"land": land["land"], "outcome": land["outcome"], "attempts": land["attempts"], "error": land.get("error"),
             "connections": [{k: c[k] for k in ("key", "instance", "outcome", "reconnected", "differences", "paths")}
                             for c in land["connections"] if c["outcome"] != "converged"]}
            for land in report["lands"] if land["outcome"] != "converged"
        ],
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
