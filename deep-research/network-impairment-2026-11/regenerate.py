#!/usr/bin/env python3
"""Regenerate the Results tables in README.md from results/*.json.

No arguments (or --markdown): print the tables. --check: print OK or MISMATCH against README's
## Results section, exit 0 or 1. Stdlib only. The tables use analysis.py's definitions (§ 5 of
Notes/plans/2026-11-07-network-impairment-experiment-design.md).
"""
import argparse
import json
import pathlib
import statistics
from collections import Counter
import sys

import analysis as a
import clientload

HERE = pathlib.Path(__file__).parent


def load_runs() -> dict[str, dict]:
    return {p.stem: json.loads(p.read_text()) for p in sorted((HERE / "results").glob("*.json"))}


def cell_of(run: dict) -> tuple:
    """Runs of one cell share a load point and a population."""
    return (run["params"]["rooms"], run["params"]["population"])


# SR has no P0 of its own: its control is M's P0, the same topology, rooms and instances (§ 4).
CONTROL_POPULATION = {"SR": "M"}


def control_cell(run: dict) -> tuple:
    """The cell whose P0 repeats are this run's control."""
    rooms, population = cell_of(run)
    return (rooms, CONTROL_POPULATION.get(population, population))


# A profile with fewer lines in the run's span than this share of its 1 s windows is missing.
PROFILE_COVERAGE = 0.95


def missing_inputs(run: dict, group: str | None = None) -> list[str]:
    """What a hard criterion needs and the run lacks. Every missing input fails the criterion
    ("fail (missing: ...)"); none is skipped or read as 0. With ``group``, that group's inputs
    only: its worker files, its population (distinct join keys against ``target``) and a
    positive ``sendTargetPerS``."""
    names = [group] if group is not None else sorted(run["groups"])
    out = []
    for name in names:
        g = run["groups"][name]
        manifest = g.get("manifest") or {}
        if not manifest.get("files"):
            out.append(f"{name} samples")
        elif manifest.get("joinKeys") != g["target"]:
            out.append(f"{name} joins {manifest.get('joinKeys')}/{g['target']}")
        if not (g.get("sendTargetPerS") or 0) > 0:
            out.append(f"{name} sendTargetPerS")
        # Input-to-visible (§ 7): unimpaired, every input is seen. Few seen in the baseline means
        # the matcher missed the echo's wire shape, not a slow server.
        base = [w for w in g.get("windows", []) if w["segment"] == "baseline"]
        sent, seen = sum(w["inputsSent"] for w in base), sum(w["inputsSeen"] for w in base)
        if sent < a.MIN_INPUT_SAMPLES:
            out.append(f"{name} baseline inputs ({sent} sent)")
        elif seen < a.MATCHER_MIN_SEEN_SHARE * sent:
            out.append(f"{name} baseline inputs seen {seen}/{sent} (input-to-visible matcher)")
        # The client-bound gate's input (§ 2): without it a client-bound window can't be told.
        loop = g.get("loop") or {}
        if not loop.get("spans"):
            out.append(f"{name} loop samples")
        for worker, gap in sorted((loop.get("uncovered") or {}).items()):
            out.append(f"{name} loop spans for worker {worker} ({gap})")
    return out


def controls_missing(controls: dict[str, dict], group: str) -> list[str]:
    """The P0 controls' own missing inputs for ``group``: a control with a lost worker file would
    give a band from fewer samples, so it fails the criterion it controls."""
    return [f"control {cid}: {m}" for cid, c in sorted(controls.items()) if group in c["groups"]
            for m in missing_inputs(c, group)]


def counters_missing(run: dict) -> bool:
    """The transport profile is missing, or covers too little of the run's span."""
    srv = run.get("server")
    expected = run.get("expectedProfileWindows")
    return srv is None or not expected or srv.get("windows", 0) < PROFILE_COVERAGE * expected


def fail_missing(reasons: list[str]) -> str:
    return "fail (missing: " + ", ".join(reasons) + ")"


def quiet_windows(run: dict, group: str) -> list[dict]:
    """P0's quiet windows for the band: its baseline and impaired segments, client-bound ones
    left out (§ 2)."""
    return [w for w in run["groups"][group]["windows"]
            if w["segment"] in ("baseline", "impaired") and not w.get("clientBound")]


def group_recovery(run: dict, group: str, edges: dict) -> int | None:
    g = run["groups"][group]
    recovery = [w for w in g["windows"] if w["segment"] == "recovery"]
    send_target = g["sendTargetPerS"] * a.WINDOW_MS / 1000
    states = [a.health(w, g["target"], send_target, edges) for w in recovery]
    return a.recovery_ms(states, [w["start"] for w in recovery], run["timeline"]["liftedAt"])


# The profiles with jitter (design § 3), the only ones ``params.jitterReorders`` applies to.
JITTER_PROFILES = {"D50J10", "COMBO"}


def label(run: dict) -> str:
    """The profile as the tables show it. A jitter cell on a host whose netem reorders (the
    acceptance smoke's out-of-order count above 0, recorded as ``params.jitterReorders``) runs as
    jitter with reordering (design § 1), and is labelled so. The rules still go by the profile.
    A profile without jitter can't reorder: ``jitterReorders`` on one is a bad run.json."""
    profile = run["params"]["profile"]
    if run["params"].get("jitterReorders") and profile not in JITTER_PROFILES:
        raise ValueError(f"params.jitterReorders is set on {profile}, which has no jitter (only {sorted(JITTER_PROFILES)})")
    return f"{profile} (reordering)" if run["params"].get("jitterReorders") else profile


def reordered(value) -> str:
    """``params.reorderedPct`` as shown: per direction (``{"down": .., "up": ..}``), or one value.
    Reported, not gated; a reordering run without it shows "fail (missing: ...)", like every
    other missing input."""
    if value is None:
        return fail_missing(["reorderedPct"])
    if isinstance(value, dict):
        absent = [f"reorderedPct.{d}" for d in ("down", "up") if d not in value]
        if absent:
            return fail_missing(absent)
        return ", ".join(f"{value[d]} {d}" for d in ("down", "up"))
    return str(value)


def reorder_rows(runs: dict[str, dict]) -> list[tuple]:
    """The runs with reordering jitter, and the measured reordering: ``params.reorderedPct``, the
    calibration capture's share of data segments whose sequence number decreased within a flow,
    retransmissions excluded, per direction (design § 1)."""
    return [(rid, label(run), reordered(run["params"].get("reorderedPct")))
            for rid, run in sorted(runs.items()) if run["params"].get("jitterReorders")]


def recovery_rows(runs: dict[str, dict]) -> list[tuple]:
    """Per cell, profile and group: recoveryMs per repeat against the cell's P0 band. A P0
    repeat is tested against the other two (leave-one-out): the false-positive control. A repeat
    with a missing input, or without a control, fails."""
    rows = []
    cells = sorted({cell_of(r) for r in runs.values()})
    for cell in cells:
        in_cell = {rid: r for rid, r in runs.items() if cell_of(r) == cell}
        control = control_cell(next(iter(in_cell.values())))
        p0 = {rid: r for rid, r in runs.items() if cell_of(r) == control and r["params"]["profile"] == "P0"}
        groups = sorted({g for r in in_cell.values() for g in r["groups"]})
        for profile in sorted({r["params"]["profile"] for r in in_cell.values()}):
            for group in groups:
                values = []
                for rid, run in sorted(in_cell.items()):
                    if run["params"]["profile"] != profile or group not in run["groups"]:
                        continue
                    others = {cid: r for cid, r in p0.items() if cid != rid}
                    missing = missing_inputs(run, group) + controls_missing(others, group)
                    if missing:
                        values.append(fail_missing(missing))
                        continue
                    controls = [quiet_windows(r, group) for cid, r in sorted(others.items()) if group in r["groups"]]
                    if not controls:
                        values.append("fail (no control)")
                        continue
                    remnant = too_client_bound([w for w in run["groups"][group]["windows"] if w["segment"] == "recovery"])
                    if remnant:
                        values.append(remnant)
                        continue
                    values.append(group_recovery(run, group, a.band(controls)))
                shown = next(label(r) for r in in_cell.values() if r["params"]["profile"] == profile)
                rows.append((cell, shown, group, values))
    return rows


def fmt_recovery(values: list) -> str:
    finite = [v for v in values if isinstance(v, int)]
    shown = ", ".join("not recovered" if v is None else str(v) for v in values)
    median = f"{statistics.median(finite):.0f}" if finite and len(finite) == len(values) else "–"
    return f"{median} | {shown}"


# Profiles whose stale closes are a failure (§ 7): frames every 100 ms should never let it fire.
STALE_IS_FAILURE = {"P0", "D50J10"}
HEALTHY_GROUPS_PREFIX = "healthy"


def client_bound_share(windows_: list[dict]) -> float:
    return sum(1 for w in windows_ if w.get("clientBound")) / len(windows_) if windows_ else 0.0


def too_client_bound(windows_: list[dict]) -> str | None:
    """"inconclusive (n % client-bound)" when more than ``CLIENT_BOUND_MAX_SHARE`` of the windows
    are client-bound: a verdict from the remnant isn't one."""
    share = client_bound_share(windows_)
    return f"inconclusive ({share:.0%} client-bound)" if share > a.CLIENT_BOUND_MAX_SHARE else None


def p0_controls(runs: dict[str, dict], rid: str) -> dict[str, dict]:
    """The P0 repeats of ``rid``'s control cell, without ``rid`` itself (leave-one-out for P0)."""
    cell = control_cell(runs[rid])
    return {cid: r for cid, r in runs.items() if cell_of(r) == cell and r["params"]["profile"] == "P0" and cid != rid}


def session_rows(runs: dict[str, dict]) -> list[tuple]:
    """Per run and group: sessions that recovered (survivors and firstSync rebuilds apart), and
    those that didn't, against the per-session band of the cell's other P0 repeats. Without a
    band the row fails (no control), but its counts still show what the sessions did apart from
    the band: open at the end, and rebuilt by a firstSync if they reconnected."""
    rows = []
    for rid, run in sorted(runs.items()):
        controls = p0_controls(runs, rid)
        for group, g in sorted(run["groups"].items()):
            band_edge = a.session_band([c["groups"][group]["sessions"] for c in controls.values() if group in c["groups"]])
            survived = rebuilt = lost = 0
            # Without a band, count against none (every gap within it); the verdict still fails.
            counted_edge = band_edge if band_edge is not None else float("inf")
            for s in g["sessions"].values():
                if not a.session_recovered(s, counted_edge):
                    lost += 1
                elif s["reconnected"]:
                    rebuilt += 1
                else:
                    survived += 1
            missing = missing_inputs(run, group) + controls_missing(controls, group)
            if missing:
                verdict = fail_missing(missing)
            elif band_edge is None:
                verdict = "fail (no control)"
            else:
                verdict = "pass" if lost == 0 else "fail"
            rows.append((rid, label(run), group, survived, rebuilt, lost, band_edge, verdict))
    return rows


def close_rows(runs: dict[str, dict]) -> list[tuple]:
    """Per run: the closes the clients saw, by kind, and the server's counted causes. Counts
    only: matching each close to its session's cause needs the server's per-session log."""
    rows = []
    for rid, run in sorted(runs.items()):
        closes = [c for g in run["groups"].values() for c in g["closes"]]
        server_side = sum(1 for c in closes if c["initiator"] == "server")
        stale = sum(1 for c in closes if c.get("cause") == "stale")
        stale_slow = sum(1 for c in closes if c.get("cause") == "stale" and c.get("slowReader"))
        srv = run.get("server") or {}
        profile = run["params"]["profile"]
        missing = missing_inputs(run)
        if profile not in STALE_IS_FAILURE and profile != "SR":
            stale_verdict = "reported"
        elif missing:
            stale_verdict = fail_missing(missing)
        elif profile in STALE_IS_FAILURE:
            stale_verdict = "fail" if stale else "pass"
        else:
            stale_verdict = "fail" if stale_slow else "pass"
        rows.append((rid, label(run), server_side, srv.get("pongTimeoutCloses", "–"), srv.get("sendBacklogCloses", "–"),
                     stale, stale_verdict, srv.get("sendBufferedBytesMax", "–")))
    return rows


# The profile's counters against the log's causes (D1). A counter can exceed the log: it counts a
# backlog breach after a pong close was decided, sessions that never joined, and closes on the
# other side of a segment edge. So each counter must be at least its causes' count, and the excess
# is reported; a counter below the log is a fault.
COUNTER_CAUSES = {"pongTimeoutCloses": ("pongTimeout",), "sendBacklogCloses": ("backlogBytes", "backlogUnwritable")}


def counter_excess(run: dict) -> dict[str, int] | None:
    """Per counter, the counter minus the log's count of its causes; ``None`` when the profile
    is missing, covers too little, or never carries one of the counters."""
    if counters_missing(run) or not set(COUNTER_CAUSES) <= set(run["server"].get("seen", ())):
        return None
    causes = run["sessionCloseCauses"]
    return {k: run["server"].get(k, 0) - sum(causes.get(c, 0) for c in cs) for k, cs in COUNTER_CAUSES.items()}


def match_rows(runs: dict[str, dict]) -> list[tuple]:
    """§ 7 criterion 2, per run: the client closes, how many have their session's server cause,
    the client closes without one and the server-decided closes no client saw (both fail), the
    client joins that map to no server session (fail), the causes, and each profile counter's
    excess over the log's count of its causes (below 0 fails). Every run has a row: a run without
    its lifecycle log, profile or samples fails as missing."""
    rows = []
    for rid, run in sorted(runs.items()):
        missing = missing_inputs(run)
        causes = run.get("sessionCloseCauses")
        groups = [g.get("closeMatch") for g in run["groups"].values()]
        unjoined = run.get("unjoinedServerCloses")
        if causes is None or run.get("serverOnly") is None or unjoined is None or any(g is None for g in groups):
            missing.append("lifecycle log")
            rows.append((rid, label(run), "–", "–", "–", "–", "–", "–", "–", "–", "–", fail_missing(missing)))
            continue
        closes = [c for g in groups for c in g["closes"]]
        # Closes during a join pair by code and time with the server closes no client close matched
        # (no join sample, no player on a never-joined session's line); leftovers are unmatched.
        during = [c for g in groups for c in g["duringJoinServer"]]
        pairs = a.pair_by_code(during, run["serverOnly"])
        server_codes = Counter(str(c["code"]) for c in unjoined)
        unmatched = sum(g["unmatchedClient"] for g in groups) + len(pairs["client"])
        server_only = len(pairs["server"])
        unmapped = sum(g["joinsWithoutServerPlayer"] + g["unmappedJoins"] for g in groups)
        join_causes = Counter(c["cause"] for c in unjoined)
        during_join = f"{len(during)}" + (
            " (" + ", ".join(f"{k} {v}" for k, v in sorted(join_causes.items())) + ")" if join_causes else "")
        # The by-code match can't tell two closes with one code apart; a repeated code shows here.
        never_joined = (", ".join(f"{k} ×{v}" for k, v in sorted(server_codes.items())) or "0") + (
            f"; {pairs['ambiguous']} ambiguous" if pairs["ambiguous"] else "")
        matched = Counter(c["serverCause"] for c in closes if c["serverCause"] is not None)
        excess = counter_excess(run)
        if excess is None:
            missing.append("profile")
        shown_excess = "–" if excess is None else ", ".join(f"{k} {v:+d}" for k, v in sorted(excess.items()))
        if missing:
            verdict = fail_missing(missing)
        elif unmatched or server_only or unmapped or any(v < 0 for v in excess.values()):
            verdict = "fail"
        elif pairs["ambiguous"]:
            # Not final: a per-connection key has to tell these pairs apart first (§ 7).
            verdict = f"pending ({pairs['ambiguous']} ambiguous pairs)"
        else:
            verdict = "pass"
        rows.append((rid, label(run), len(closes), sum(matched.values()), unmatched, server_only, unmapped,
                     during_join, never_joined, ", ".join(f"{k} {v}" for k, v in sorted(matched.items())) or "–", shown_excess, verdict))
    return rows


# The per-profile hard criteria (§ 7) for the sessions an impaired group had open at the apply:
# which server-side causes must close them, and by when, from the lift, a firstSync must rebuild
# them (None: by the end of the recovery segment).
BACKLOG_CAUSES = {"backlogBytes", "backlogUnwritable"}
PROFILE_CRITERIA = {
    "BO75": {"causes": {"pongTimeout"} | BACKLOG_CAUSES, "rebuildWithinMs": 60_000},
    "SR": {"causes": BACKLOG_CAUSES, "rebuildWithinMs": None},
}


def profile_rows(runs: dict[str, dict]) -> list[tuple]:
    """BO75 and SR, per run and impaired group: every session open at the apply closed on the
    server by one of the profile's causes before the end of recovery, and rebuilt by a firstSync
    in time; for BO75 also every stale close in the run matched to a pong or backlog close of its
    session by the end of recovery. A group with fewer subjects than its target, or a missing
    input, fails."""
    rows = []
    for rid, run in sorted(runs.items()):
        profile = run["params"]["profile"]
        rule = PROFILE_CRITERIA.get(profile)
        if rule is None:
            continue
        lifted = run["timeline"]["liftedAt"]
        end = lifted + a.RECOVERY_MS
        deadline = end if rule["rebuildWithinMs"] is None else lifted + rule["rebuildWithinMs"]
        stale_bad = None
        if profile == "BO75" and all(g.get("closeMatch") is not None for g in run["groups"].values()):
            stale = [c for g in run["groups"].values() for c in g["closeMatch"]["closes"] if c.get("cause") == "stale"]
            stale_bad = sum(1 for c in stale if c["serverCause"] not in rule["causes"] or c["serverT"] >= end)
        for group, g in sorted(run["groups"].items()):
            if group.startswith(HEALTHY_GROUPS_PREFIX):
                continue
            missing = missing_inputs(run, group)
            subjects = g.get("outageSessions")
            if subjects is None:
                missing.append("lifecycle log")
            if missing:
                rows.append((rid, label(run), group, "–", "–", "–", "–", fail_missing(missing)))
                continue
            closed = sum(1 for s in subjects if s["serverCause"] in rule["causes"] and s["serverT"] < end)
            rebuilt = sum(1 for s in subjects if s["firstSyncAt"] is not None and s["firstSyncAt"] <= deadline)
            if len(subjects) != g["target"]:
                verdict = f"fail ({len(subjects)}/{g['target']} open at the apply)"
            elif closed == rebuilt == len(subjects) and not stale_bad:
                verdict = "pass"
            else:
                verdict = "fail"
            rows.append((rid, label(run), group, len(subjects), closed, rebuilt,
                         "–" if stale_bad is None else stale_bad, verdict))
    return rows


# § 7's profiles that allow no server-initiated close, and those that also allow no unanswered
# action outside the impaired segment.
ZERO_SERVER_CLOSES = {"P0", "D50J10", "D50", "ASYM", "L1", "GE", "BO10"}
NO_UNANSWERED_OUTSIDE = {"P0", "D50J10", "D50", "ASYM"}


def quiet_rows(runs: dict[str, dict]) -> list[tuple]:
    """Per run of a profile that allows no server-initiated close (§ 7): the server-decided closes
    in the lifecycle log within the run, joined or not, and the server-initiated closes the clients
    saw, joined or during a join; either fails. For P0 and D50J10 also the unanswered actions
    outside the impaired segment. A missing input fails."""
    rows = []
    for rid, run in sorted(runs.items()):
        profile = run["params"]["profile"]
        if profile not in ZERO_SERVER_CLOSES:
            continue
        missing = missing_inputs(run)
        causes = run.get("sessionCloseCauses")
        if causes is None:
            missing.append("lifecycle log")
        server = sum(v for k, v in causes.items() if k in a.SERVER_DECIDED) if causes is not None else None
        client = sum(1 for g in run["groups"].values() for c in g["closes"] if c["initiator"] == "server") + sum(
            (g.get("closeMatch") or {}).get("duringJoin", {}).get("server", 0) for g in run["groups"].values())
        unanswered = None
        if profile in NO_UNANSWERED_OUTSIDE:
            unanswered = sum(w["unanswered"] for g in run["groups"].values() for w in g["windows"]
                             if w["segment"] != "impaired")
        if missing:
            verdict = fail_missing(missing)
        else:
            verdict = "fail" if server or client or unanswered else "pass"
        rows.append((rid, label(run), server, client, "not required" if unanswered is None else unanswered, verdict))
    return rows


def client_bound_rows(runs: dict[str, dict]) -> list[tuple]:
    """Per run and group (§ 2): the client-bound windows by segment, which isolation and recovery
    leave out; each worker's largest span ELU, below the gate too, for the headroom; the largest
    window send-lag p99; and the gate's check against the run-wide loop-delay p99: a run over
    ``LOOP_DELAY_P99_LIMIT_MS`` with no client-bound window means the gate is set too high."""
    rows = []
    for rid, run in sorted(runs.items()):
        for group, g in sorted(run["groups"].items()):
            loop = g.get("loop") or {}
            bound = Counter(w["segment"] for w in g["windows"] if w.get("clientBound"))
            by_segment = ", ".join(f"{s} {bound[s]}" for s in a.SEGMENTS)
            worst = loop.get("maxEluByWorker") or {}
            elu = ", ".join(f"{w} {v}" for w, v in worst.items()) or None
            lags = [w["sendLagP99"] for w in g["windows"] if w.get("sendLagP99") is not None]
            loop_p99 = g.get("loopDelayP99Ms")
            if not loop.get("spans"):
                check = fail_missing([f"{group} loop samples"])
            elif loop_p99 is None:
                check = "missing: run-wide loop-delay p99"
            elif loop_p99 > a.LOOP_DELAY_P99_LIMIT_MS and not bound:
                check = f"gate too high? (loop-delay p99 {loop_p99} ms, no client-bound window)"
            else:
                check = "consistent"
            rows.append((rid, label(run), group, by_segment, elu, max(lags) if lags else None, loop_p99, check))
    return rows


def isolation_rows(runs: dict[str, dict]) -> list[tuple]:
    """Healthy groups in impaired runs (§ 7): the impaired segment's pooled p99 of move-event
    latency and update gap, against the worst same-length segment of the cell's P0 repeats."""
    rows = []
    for rid, run in sorted(runs.items()):
        if run["params"]["profile"] == "P0":
            continue
        controls = p0_controls(runs, rid)
        for group, g in sorted(run["groups"].items()):
            if not group.startswith(HEALTHY_GROUPS_PREFIX):
                continue
            missing = missing_inputs(run, group)
            # § 7: every healthy group has zero closes, joined or during a join, and zero
            # unanswered actions, over the whole run.
            closes = len(g["closes"]) + sum(((g.get("closeMatch") or {}).get("duringJoin") or {}).values())
            if g.get("closeMatch") is None:
                missing = missing + ["lifecycle log"]
            unanswered = sum(w["unanswered"] for w in g["windows"])
            rows.append((rid, label(run), group, "closes, unanswered", f"{closes}, {unanswered}", "0, 0",
                         fail_missing(missing) if missing else ("yes" if closes == unanswered == 0 else "no")))
            missing = missing_inputs(run, group) + controls_missing(controls, group)
            segment = [w for w in g["windows"] if w["segment"] == "impaired"]
            impaired = [w for w in segment if not w.get("clientBound")]
            # The run's own impaired segment, and each control's quiet windows, need enough left.
            remnant = too_client_bound(segment) or next(
                (f"{msg} in control {cid}" for cid, c in sorted(controls.items()) if group in c["groups"]
                 for msg in [too_client_bound([w for w in c["groups"][group]["windows"]
                                                if w["segment"] in ("baseline", "impaired")])] if msg), None)
            quiet = [quiet_windows(c, group) for c in controls.values() if group in c["groups"]]
            for stat, key in (("inputP99", "inputHist"), ("gapP99", "gapHist")):
                value = a.pooled(impaired, key)
                edge = a.segment_band(quiet, len(impaired), key)
                if missing:
                    within = fail_missing(missing)
                elif remnant:
                    within = remnant
                elif value is None:
                    within = "fail (missing: impaired samples)"
                elif edge is None:
                    within = "fail (no control)"
                else:
                    within = "yes" if value <= edge else "no"
                rows.append((rid, label(run), group, stat, value, edge, within))
    return rows


def memory_rows(runs: dict[str, dict]) -> list[tuple]:
    """Per run (§ 7, criterion 5): the leak check, the RSS slope over the last 30 s of recovery
    at most the largest slope of the cell's other P0 repeats plus 1 MiB/s (hard); and, reported,
    the peak RSS while impaired, how far the end RSS is above P0's peak, and the kernel's peaks."""
    rows = []
    for rid, run in sorted(runs.items()):
        mem = run.get("memory")
        if not mem:
            rows.append((rid, label(run), None, None, fail_missing(["memory samples"]), None, None, None))
            continue
        control_runs = p0_controls(runs, rid)
        controls = [c["memory"] for c in control_runs.values() if c.get("memory")]
        p0_slopes = [m["rssSlopeLast30sMbPerS"] for m in controls if m["rssSlopeLast30sMbPerS"] is not None]
        uncovered = [cid for cid, c in sorted(control_runs.items())
                     if not c.get("memory") or c["memory"]["rssSlopeLast30sMbPerS"] is None]
        p0_peaks = [m[seg]["rssPeakMb"] for m in controls for seg in a.SEGMENTS if m[seg]["rssPeakMb"] is not None]
        slope = mem["rssSlopeLast30sMbPerS"]
        if slope is None:
            leak = fail_missing(["RSS over the last 30 s"])
        elif uncovered:
            leak = fail_missing([f"control {cid} RSS over the last 30 s" for cid in uncovered])
        elif not p0_slopes:
            leak = "fail (no control)"
        else:
            leak = "pass" if slope <= max(p0_slopes) + a.LEAK_SLOPE_MARGIN else "fail"
        above = None if mem["rssAtEndMb"] is None or not p0_peaks else round(mem["rssAtEndMb"] - max(p0_peaks), 1)
        rows.append((rid, label(run), mem["impaired"]["rssPeakMb"],
                     None if slope is None else round(slope, 3), leak, above,
                     mem["impaired"]["hostTcpMemPeakPages"], mem["impaired"]["serverSendQPeakBytes"]))
    return rows


def roster_difference(expected: dict, actual: dict) -> str | None:
    """How the report's roster shape differs from ``params.convergenceRoster``, or ``None``."""
    expected = {i: {str(k): v for k, v in shape.items()} for i, shape in expected.items()}
    parts = []
    for instance in sorted(set(expected) | set(actual)):
        want, got = expected.get(instance), actual.get(instance)
        if want != got:
            show_shape = lambda s: "none" if not s else ", ".join(f"{n} in {rooms}" for n, rooms in s.items())
            parts.append(f"{instance} {show_shape(got)}, expected {show_shape(want)}")
    return "; ".join(parts) or None


def convergence_rows(runs: dict[str, dict]) -> list[tuple]:
    """Per run (§ 7, criterion 3): every room converged. ``mismatched``, ``missingClients`` and
    errored rooms must be 0 and every room of the run checked, after the one retry of an
    inconclusive room; a room still inconclusive marks the run inconclusive, not passed. The row
    shows the rooms checked before the driver's deadline and the pass's wall time, so a run
    that ran out of time shows at once. A room
    whose difference went away within the cap converged late: its own column, with the largest
    delay, not a fail. The roster (connections per room per instance) must match the run's
    ``params.convergenceRoster``, so an instance left out of the check can't pass. The survivors'
    and the reconnected connections' rows are reported apart (§ 6), late ones included."""
    rows = []
    for rid, run in sorted(runs.items()):
        conv = run.get("convergence")
        expected = run["params"].get("convergenceRoster")
        missing = ([] if conv is not None else ["convergence"]) + ([] if expected is not None else ["params.convergenceRoster"])
        if conv is not None and conv.get("roster") is None:
            missing.append("convergence roster")
        if missing:
            rows.append((rid, label(run)) + (None,) * 10 + (fail_missing(missing),))
            continue
        t = conv["totals"]
        rooms = run["params"]["rooms"]
        roster = roster_difference(expected, conv["roster"])
        # Rooms the pass reached before its deadline; the ones it didn't are errors too, but get
        # their own verdict: a run that checks fewer than all is rerun with a longer tail.
        checked = t["lands"] - t["uncheckedAtDeadline"]
        if t["lands"] == 0:
            verdict = "fail (no rooms checked)"
        elif t["lands"] != rooms:
            verdict = f"fail ({t['lands']} of {rooms} rooms listed)"
        elif checked != rooms:
            verdict = f"fail ({checked} of {rooms} rooms checked before the deadline)"
        elif roster:
            verdict = f"fail (roster: {roster})"
        elif t["mismatched"] or t["missingClients"] or t["errors"]:
            verdict = "fail"
        elif t["inconclusive"]:
            verdict = f"inconclusive ({t['inconclusive']} rooms)"
        else:
            verdict = "pass"
        late = t["convergedLate"]
        late_cell = f"{late} (max {t['lateMaxMs']} ms)" if late else "0"
        share = lambda r: f"{r['converged'] + r['convergedLate']}/{r['compared']}"
        rows.append((rid, label(run), f"{checked}/{rooms}", t["converged"], late_cell, t["mismatched"], t["missingClients"], t["inconclusive"],
                     t["errors"], share(t["survivors"]), share(t["reconnected"]), round(conv["durationMs"] / 1000, 1), verdict))
    return rows


def show(v) -> str:
    return "–" if v is None else str(v)


def tables(runs: dict[str, dict]) -> str:
    if not runs:
        return "_No runs yet._\n"
    out = [
        "### Recovery (recoveryMs, from the lift)",
        "",
        "| rooms | population | profile | group | median | per repeat |",
        "|---|---|---|---|---|---|",
    ]
    for (rooms, population), profile, group, values in recovery_rows(runs):
        out.append(f"| {rooms} | {population} | {profile} | {group} | {fmt_recovery(values)} |")
    out += [
        "",
        "### Per-session recovery (end of the recovery segment)",
        "",
        "| run | profile | group | survived | rebuilt (firstSync) | not recovered | band (gap p99, ms) | verdict |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for row in session_rows(runs):
        out.append("| " + " | ".join(show(v) for v in row) + " |")
    out += [
        "",
        "### Closes and server causes (counts)",
        "",
        "| run | profile | server-initiated (client) | pong timeout (server) | backlog 4008 (server) | stale (client) | stale rule | sendBufferedBytesMax |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for row in close_rows(runs):
        out.append("| " + " | ".join(show(v) for v in row) + " |")
    out += [
        "",
        "### Every close has a cause (per session)",
        "",
        "| run | profile | client closes | with server cause | client close, no cause | server close, no client close | joins without a server session | server closes during a join | never-joined server closes by code | causes | counter minus log | criterion 2 |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for row in match_rows(runs):
        out.append("| " + " | ".join(show(v) for v in row) + " |")
    out += [
        "",
        "### Every room converged (after recovery)",
        "",
        "| run | profile | rooms checked before the deadline | converged | converged late (≤ 5 s) | mismatched | missing clients | inconclusive | errors | survivors converged | reconnected converged | check (s) | criterion 3 |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for row in convergence_rows(runs):
        out.append("| " + " | ".join(show(v) for v in row) + " |")
    quiet = quiet_rows(runs)
    if quiet:
        out += [
            "",
            "### Profiles without server closes (P0, D50J10, L1)",
            "",
            "| run | profile | server-decided closes (log) | server-initiated closes (clients) | unanswered outside the impaired segment | verdict |",
            "|---|---|---|---|---|---|",
        ]
        for row in quiet:
            out.append("| " + " | ".join(show(v) for v in row) + " |")
    per_profile = profile_rows(runs)
    if per_profile:
        out += [
            "",
            "### Per-profile criteria (BO75, SR)",
            "",
            "| run | profile | group | open at the apply | closed by the profile's server cause | rebuilt by a firstSync in time | stale closes without pong or backlog | verdict |",
            "|---|---|---|---|---|---|---|---|",
        ]
        for row in per_profile:
            out.append("| " + " | ".join(show(v) for v in row) + " |")
    reorder = reorder_rows(runs)
    if reorder:
        out += [
            "",
            "### Jitter with reordering",
            "",
            "| run | profile | reordered data segments (%, per direction) |",
            "|---|---|---|",
        ]
        for row in reorder:
            out.append("| " + " | ".join(show(v) for v in row) + " |")
    mem = memory_rows(runs)
    if mem:
        out += [
            "",
            "### Memory",
            "",
            "| run | profile | peak RSS impaired (MiB) | RSS slope, last 30 s (MiB/s) | leak check | end RSS above P0 peak (MiB) | host TCP mem peak (pages) | server Send-Q peak (bytes) |",
            "|---|---|---|---|---|---|---|---|",
        ]
        for row in mem:
            out.append("| " + " | ".join(show(v) for v in row) + " |")
    bound = client_bound_rows(runs)
    if bound:
        out += [
            "",
            "### Client-bound windows (excluded from isolation and recovery)",
            "",
            f"| run | profile | group | client-bound windows (ELU > {a.CLIENT_BOUND_ELU}) | largest span ELU per worker | largest window send-lag p99 (ms) | run-wide loop-delay p99 (ms) | gate check |",
            "|---|---|---|---|---|---|---|---|",
        ]
        for row in bound:
            out.append("| " + " | ".join(show(v) for v in row) + " |")
    iso = isolation_rows(runs)
    if iso:
        out += [
            "",
            "### Isolation (healthy groups, impaired segment)",
            "",
            "| run | profile | group | statistic | value (ms) | P0 band (ms) | within |",
            "|---|---|---|---|---|---|---|",
        ]
        for row in iso:
            out.append("| " + " | ".join(show(v) for v in row) + " |")
    return "\n".join(out) + "\n"


def unusable(runs: dict[str, dict]) -> list[str]:
    """Runs that can't enter the sweep's tables: a smoke run (calibration overrides), a run of
    the driver's test hooks (a scenario override, a start margin), or one whose sweep didn't build
    the server and the client (run.sh BUILD=0, its record's `build`)."""
    out = []
    for rid, run in sorted(runs.items()):
        meta, params = run.get("meta") or {}, run.get("params") or {}
        dirty = (meta.get("git") or {}).get("dirty")
        if dirty is not False:
            out.append(f"{rid}: not from a clean tree (git dirty: {dirty})")
        backlog = meta.get("sendBacklogEnv")
        if backlog is None or any(backlog.values()):
            out.append(f"{rid}: send-backlog settings {backlog}, not the shipped defaults (recorded and unset)")
        out.extend(f"{rid}: {why}" for why in clientload.failures(meta))
        if meta.get("build") is not True:
            out.append(f"{rid}: not built by run.sh (build {meta.get('build')!r}, GAMESERVER_BIN {meta.get('gameserverBin')!r})")
        if params.get("calibrationOverrides"):
            out.append(f"{rid}: a smoke run (calibration overrides {params['calibrationOverrides']}); keep it out of results/")
        for hook in ("scenarioOverride", "startMarginS"):
            if params.get(hook) is not None:
                out.append(f"{rid}: ran with the test hook {hook}={params[hook]!r}")
    return out


def results_section(readme: str) -> str:
    if "## Results" not in readme:
        print("README.md has no '## Results' section", file=sys.stderr)
        sys.exit(1)
    body = readme.split("## Results", 1)[1]
    body = body.split("\n## ", 1)[0]
    return body.strip("\n") + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--markdown", action="store_true")
    args = parser.parse_args()
    runs = load_runs()
    refused = unusable(runs)
    if refused:
        print("results not usable:\n  " + "\n  ".join(refused), file=sys.stderr)
        return 1
    generated = tables(runs)
    if args.check:
        readme = (HERE / "README.md").read_text()
        ok = results_section(readme) == generated
        print("OK" if ok else "MISMATCH")
        return 0 if ok else 1
    sys.stdout.write(generated)
    return 0


if __name__ == "__main__":
    sys.exit(main())
