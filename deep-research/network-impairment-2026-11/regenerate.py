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
    return out


def counters_missing(run: dict) -> bool:
    """The transport profile is missing, or covers too little of the run's span."""
    srv = run.get("server")
    expected = run.get("expectedProfileWindows")
    return srv is None or not expected or srv.get("windows", 0) < PROFILE_COVERAGE * expected


def fail_missing(reasons: list[str]) -> str:
    return "fail (missing: " + ", ".join(reasons) + ")"


def quiet_windows(run: dict, group: str) -> list[dict]:
    """P0's quiet windows for the band: its baseline and impaired segments."""
    return [w for w in run["groups"][group]["windows"] if w["segment"] in ("baseline", "impaired")]


def group_recovery(run: dict, group: str, edges: dict) -> int | None:
    g = run["groups"][group]
    recovery = [w for w in g["windows"] if w["segment"] == "recovery"]
    send_target = g["sendTargetPerS"] * a.WINDOW_MS / 1000
    states = [a.health(w, g["target"], send_target, edges) for w in recovery]
    return a.recovery_ms(states, [w["start"] for w in recovery], run["timeline"]["liftedAt"])


def label(run: dict) -> str:
    """The profile as the tables show it. A jitter cell on a host whose netem reorders (the
    acceptance smoke's out-of-order count above 0, recorded as ``params.jitterReorders``) runs as
    jitter with reordering (design § 1), and is labelled so. The rules still go by the profile."""
    profile = run["params"]["profile"]
    return f"{profile} (reordering)" if run["params"].get("jitterReorders") else profile


def reorder_rows(runs: dict[str, dict]) -> list[tuple]:
    """The runs with reordering jitter, and the measured reordering: ``params.reorderedPct``, the
    calibration capture's share of data segments whose sequence number decreased within a flow,
    retransmissions excluded (design § 1)."""
    return [(rid, label(run), run["params"].get("reorderedPct", "–"))
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
                    missing = missing_inputs(run, group)
                    if missing:
                        values.append(fail_missing(missing))
                        continue
                    controls = [quiet_windows(r, group) for cid, r in sorted(p0.items()) if cid != rid and group in r["groups"]]
                    if not controls:
                        values.append("fail (no control)")
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


def p0_controls(runs: dict[str, dict], rid: str) -> dict[str, dict]:
    """The P0 repeats of ``rid``'s control cell, without ``rid`` itself (leave-one-out for P0)."""
    cell = control_cell(runs[rid])
    return {cid: r for cid, r in runs.items() if cell_of(r) == cell and r["params"]["profile"] == "P0" and cid != rid}


def session_rows(runs: dict[str, dict]) -> list[tuple]:
    """Per run and group: sessions that recovered (survivors and firstSync rebuilds apart), and
    those that didn't, against the per-session band of the cell's other P0 repeats. Without a
    band no session recovers, and the row fails (no control)."""
    rows = []
    for rid, run in sorted(runs.items()):
        controls = p0_controls(runs, rid)
        for group, g in sorted(run["groups"].items()):
            band_edge = a.session_band([c["groups"][group]["sessions"] for c in controls.values() if group in c["groups"]])
            survived = rebuilt = lost = 0
            for s in g["sessions"].values():
                if not a.session_recovered(s, band_edge):
                    lost += 1
                elif s["reconnected"]:
                    rebuilt += 1
                else:
                    survived += 1
            missing = missing_inputs(run, group)
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
        if profile in STALE_IS_FAILURE:
            stale_verdict = "fail" if stale else "pass"
        elif profile == "SR":
            stale_verdict = "fail" if stale_slow else "pass"
        else:
            stale_verdict = "reported"
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
    is missing or covers too little."""
    if counters_missing(run):
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
        if causes is None or run.get("serverOnly") is None or any(g is None for g in groups):
            missing.append("lifecycle log")
            rows.append((rid, label(run), "–", "–", "–", "–", "–", "–", "–", fail_missing(missing)))
            continue
        closes = [c for g in groups for c in g["closes"]]
        unmatched = sum(g["unmatchedClient"] for g in groups)
        server_only = len(run["serverOnly"])
        unmapped = sum(g["joinsWithoutServerPlayer"] + g["unmappedJoins"] for g in groups)
        matched = Counter(c["serverCause"] for c in closes if c["serverCause"] is not None)
        excess = counter_excess(run)
        if excess is None:
            missing.append("profile")
        shown_excess = "–" if excess is None else ", ".join(f"{k} {v:+d}" for k, v in sorted(excess.items()))
        if missing:
            verdict = fail_missing(missing)
        elif unmatched or server_only or unmapped or any(v < 0 for v in excess.values()):
            verdict = "fail"
        else:
            verdict = "pass"
        rows.append((rid, label(run), len(closes), sum(matched.values()), unmatched, server_only, unmapped,
                     ", ".join(f"{k} {v}" for k, v in sorted(matched.items())) or "–", shown_excess, verdict))
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
            impaired = [w for w in g["windows"] if w["segment"] == "impaired"]
            quiet = [quiet_windows(c, group) for c in controls.values() if group in c["groups"]]
            for stat, key in (("inputP99", "inputHist"), ("gapP99", "gapHist")):
                value = a.pooled(impaired, key)
                edge = a.segment_band(quiet, len(impaired), key)
                within = "–" if value is None or edge is None else ("yes" if value <= edge else "no")
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
            continue
        controls = [c["memory"] for c in p0_controls(runs, rid).values() if c.get("memory")]
        p0_slopes = [m["rssSlopeLast30sMbPerS"] for m in controls if m["rssSlopeLast30sMbPerS"] is not None]
        p0_peaks = [m[seg]["rssPeakMb"] for m in controls for seg in a.SEGMENTS if m[seg]["rssPeakMb"] is not None]
        slope = mem["rssSlopeLast30sMbPerS"]
        if slope is None or not p0_slopes:
            leak = "–"
        else:
            leak = "pass" if slope <= max(p0_slopes) + a.LEAK_SLOPE_MARGIN else "fail"
        above = None if mem["rssAtEndMb"] is None or not p0_peaks else round(mem["rssAtEndMb"] - max(p0_peaks), 1)
        rows.append((rid, label(run), mem["impaired"]["rssPeakMb"],
                     None if slope is None else round(slope, 3), leak, above,
                     mem["impaired"]["hostTcpMemPeakPages"], mem["impaired"]["serverSendQPeakBytes"]))
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
        "| run | profile | client closes | with server cause | client close, no cause | server close, no client close | joins without a server session | causes | counter minus log | criterion 2 |",
        "|---|---|---|---|---|---|---|---|---|---|",
    ]
    for row in match_rows(runs):
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
            "| run | profile | reordered data segments (%) |",
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
    generated = tables(load_runs())
    if args.check:
        readme = (HERE / "README.md").read_text()
        ok = results_section(readme) == generated
        print("OK" if ok else "MISMATCH")
        return 0 if ok else 1
    sys.stdout.write(generated)
    return 0


if __name__ == "__main__":
    sys.exit(main())
