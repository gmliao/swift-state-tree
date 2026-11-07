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
import sys

import analysis as a

HERE = pathlib.Path(__file__).parent


def load_runs() -> dict[str, dict]:
    return {p.stem: json.loads(p.read_text()) for p in sorted((HERE / "results").glob("*.json"))}


def cell_of(run: dict) -> tuple:
    """Runs of one cell share a load point and a population; P0's repeats are its control."""
    return (run["params"]["rooms"], run["params"]["population"])


def quiet_windows(run: dict, group: str) -> list[dict]:
    """P0's quiet windows for the band: its baseline and impaired segments."""
    return [w for w in run["groups"][group]["windows"] if w["segment"] in ("baseline", "impaired")]


def group_recovery(run: dict, group: str, edges: dict) -> int | None:
    g = run["groups"][group]
    recovery = [w for w in g["windows"] if w["segment"] == "recovery"]
    send_target = (g.get("sendTargetPerS") or 0) * a.WINDOW_MS / 1000
    states = [a.health(w, g["target"], send_target, edges) for w in recovery]
    return a.recovery_ms(states, [w["start"] for w in recovery], run["timeline"]["liftedAt"])


def recovery_rows(runs: dict[str, dict]) -> list[tuple]:
    """Per cell, profile and group: recoveryMs per repeat against the cell's P0 band. A P0
    repeat is tested against the other two (leave-one-out): the false-positive control."""
    rows = []
    cells = sorted({cell_of(r) for r in runs.values()})
    for cell in cells:
        in_cell = {rid: r for rid, r in runs.items() if cell_of(r) == cell}
        p0 = {rid: r for rid, r in in_cell.items() if r["params"]["profile"] == "P0"}
        groups = sorted({g for r in in_cell.values() for g in r["groups"]})
        for profile in sorted({r["params"]["profile"] for r in in_cell.values()}):
            for group in groups:
                values = []
                for rid, run in sorted(in_cell.items()):
                    if run["params"]["profile"] != profile or group not in run["groups"]:
                        continue
                    controls = [quiet_windows(r, group) for cid, r in sorted(p0.items()) if cid != rid and group in r["groups"]]
                    if not controls:
                        values.append("no P0 band")
                        continue
                    values.append(group_recovery(run, group, a.band(controls)))
                rows.append((cell, profile, group, values))
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
    """The P0 repeats of ``rid``'s cell, without ``rid`` itself (leave-one-out for P0)."""
    cell = cell_of(runs[rid])
    return {cid: r for cid, r in runs.items() if cell_of(r) == cell and r["params"]["profile"] == "P0" and cid != rid}


def session_rows(runs: dict[str, dict]) -> list[tuple]:
    """Per run and group: sessions that recovered (survivors and firstSync rebuilds apart), and
    those that didn't, against the per-session band of the cell's other P0 repeats."""
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
            rows.append((rid, run["params"]["profile"], group, survived, rebuilt, lost, band_edge))
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
        rows.append((rid, profile, server_side, srv.get("pongTimeoutCloses", "–"), srv.get("sendBacklogCloses", "–"),
                     stale, stale_verdict, srv.get("sendBufferedBytesMax", "–")))
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
                rows.append((rid, run["params"]["profile"], group, stat, value, edge, within))
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
        rows.append((rid, run["params"]["profile"], mem["impaired"]["rssPeakMb"],
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
        "| run | profile | group | survived | rebuilt (firstSync) | not recovered | band (gap p99, ms) |",
        "|---|---|---|---|---|---|---|",
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
