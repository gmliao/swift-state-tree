#!/usr/bin/env python3
"""Regenerate every table in README.md from results/*.json (stdlib only).

Usage: python3 regenerate.py [--markdown] | python3 regenerate.py --check

Each figure is the median over the repeats of that cell. Before any table is built, every result
must come from a release build of a clean tree with its Swift version recorded, with the cell's
definition (cells.py), its rooms and the matrix's phase lengths; and must have passed every gate
collect.py evaluated. Three gates are checked again here from the raw counts, so a result edited
by hand can't pass them: only the outcomes the cell injects (and each of them), no request
pending at the end, and the `abandonedResolvers` gauge at 0 at the end. Every cell of the matrix
must be present in every repeat.
"""
import argparse, json, pathlib, statistics, sys

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC))
import cells  # noqa: E402
sys.path.insert(0, str(TOPIC.parent))
import gameserver_wire, wireform  # noqa: E402


def wire_failure(name, run):
    """Why the run's joins weren't in the form its server environment gives (the refreeze
    defaults, through gameserver_wire), or None. The form comes from the joins when the client
    recorded them, else from the commit's ancestry (deep-research/wireform.py)."""
    intended = gameserver_wire.intended(run["params"]["env"])
    try:
        joined = wireform.join_form(run["counts"].get("joinForms"))
        encoding, features = joined if joined else (intended.encoding, None)
        if encoding is None:
            raise wireform.MissingWireForm("the join responses named no encoding")
        form = wireform.resolve(run["meta"].get("git_sha"), encoding, features=features)
    except wireform.MissingWireForm as missing:
        return f"{name}: wire form missing: {missing}"
    return next(iter(wireform.check({name: form}, intended)), None)

RESULTS = TOPIC / "results"
EMPTY = "_No results yet: the measurement host's run fills this section._"
AXES = (
    ("Failure rate (delay 200 ms, service deadline 1000 ms, framework deadline 5000 ms, 50 rooms)",
     ("baseline", "rate0", "rate10", "rate50", "rate10-jitter")),
    ("Which deadline fires (failure rate 0, 50 rooms)",
     ("rate0", "service-deadline", "framework-deadline", "framework-deadline-ignored")),
    ("Rooms", ("rate10", "rate10-r200", "framework-deadline", "framework-deadline-r200",
               "framework-deadline-ignored", "framework-deadline-ignored-r200")),
    ("Join and leave checks (10% fail, 50 rooms)", ("rate0", "join10", "leave10")),
)
LABELS = {
    "baseline": "baseline (delay 0, always succeeds)", "rate0": "rate 0", "rate10": "rate 0.1", "rate50": "rate 0.5",
    "rate10-jitter": "rate 0.1, jitter 200 ms", "rate10-r200": "rate 0.1, 200 rooms",
    "service-deadline": "service deadline (delay 1500, deadline 1000)",
    "framework-deadline": "framework deadline (delay 1500, 1000 ms), cooperative",
    "framework-deadline-r200": "framework deadline, cooperative, 200 rooms",
    "framework-deadline-ignored": "framework deadline, cancellation ignored",
    "framework-deadline-ignored-r200": "framework deadline, cancellation ignored, 200 rooms",
    "join10": "10% of joins fail", "leave10": "10% of leaves fail (2 of 4 leave per room)",
}


def load(directory):
    return [json.loads(p.read_text()) for p in sorted(directory.glob("*.json"))]


def check(runs):
    failures = []
    seen = {}
    for r in runs:
        p, m, meta, counts = r["params"], r["metrics"], r["meta"], r["counts"]
        name = f"{p['cell']} rep{p['repeat']}"
        if meta.get("build_config") != "release":
            failures.append(f"{name}: not a release build ({meta.get('build_config')})")
        if meta.get("git_dirty") is not False:
            failures.append(f"{name}: not from a clean tree (git dirty: {meta.get('git_dirty')})")
        if not meta.get("swift_version"):
            failures.append(f"{name}: no Swift version recorded")
        if wire := wire_failure(name, r):
            failures.append(wire)
        c = cells.CELLS.get(p["cell"])
        if c is None:
            failures.append(f"{name}: not a cell of the matrix")
            continue
        if (p["env"], p["outcome"], p["injects"]) != (c["env"], c["outcome"], c["injects"]):
            failures.append(f"{name}: ran with another definition than cells.py has")
        expected = (c["rooms"], cells.PRE_S, cells.STEADY_S, cells.TAIL_S)
        got = (p["rooms"], p["pre_s"], p["steady_s"], p["tail_s"])
        if got != expected:
            failures.append(f"{name}: rooms and phases {got}, the matrix has {expected}")
        for f in r["failures"]:
            failures.append(f"{name}: gate {f}")
        if not r["failures"] and not r["gates"]:
            failures.append(f"{name}: no gates evaluated")
        outcomes = counts.get("outcomes", {})
        for kind in ("failed", "timedOut"):
            n = outcomes.get(kind)
            if kind in c["injects"] and not n:
                failures.append(f"{name}: injects {kind}, none came")
            if kind not in c["injects"] and n != 0:
                failures.append(f"{name}: {n} {kind} answers, the cell injects none")
        if counts.get("pendingAtEnd") != 0:
            failures.append(f"{name}: {counts.get('pendingAtEnd')} requests pending at the end")
        if counts.get("abandonedEnd") != 0:
            failures.append(f"{name}: abandonedResolvers {counts.get('abandonedEnd')} at the end")
        seen.setdefault(p["repeat"], set()).add(p["cell"])
    for repeat, present in sorted(seen.items()):
        missing = set(cells.CELLS) - present
        if missing:
            failures.append(f"rep{repeat}: cells missing: {', '.join(sorted(missing))}")
    if failures:
        sys.exit("results not usable:\n  " + "\n  ".join(failures))


def median(runs, cell, key, section="metrics"):
    values = [r[section].get(key) for r in runs if r["params"]["cell"] == cell]
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def f0(v):
    return "–" if v is None else f"{v:,.0f}"


def gap(v):
    """A tick-gap quantile: the probe's last bucket holds every gap of 1000 ms or more."""
    return "–" if v is None else (f"≥{v:,.0f}" if v >= 1000 else f"{v:,.0f}")


def f1(v):
    return "–" if v is None else f"{v:,.1f}"


def tables(runs):
    if not runs:
        return EMPTY
    repeats = sorted({r["params"]["repeat"] for r in runs})
    present = {r["params"]["cell"] for r in runs}
    out = [f"Medians over {len(repeats)} repeat(s) ({', '.join(map(str, repeats))}). Every cell passed every gate "
           "(errors and disconnects 0, one outcome per request, only the injected outcomes, applied = state = record per room, "
           "replay, convergence, drain, tick probe contiguous). 4 players per room, 2 actions per second each, 60 s steady phase."]
    for title, members in AXES:
        members = [c for c in members if c in present]
        if not members:
            continue
        get = lambda c, k: median(runs, c, k)
        out.append(f"\n### {title}\n")
        out.append("Tick gaps on the server (ms, every land, steady phase; the period is 50 ms); the ack of the applied actions "
                   "(ms, steady phase: send to the server's answer once the resolver finished and the input was queued; the handler "
                   "applies it at the next tick, at most one tick interval later); and the ticks that passed while an applied action's "
                   "resolver ran (server side, steady phase):\n")
        out.append("| Cell | Tick gap p50 | Tick gap p99 | Tick gap max | Ack p50 | Ack p99 | Tick advance p50 | Tick advance p99 |")
        out.append("|---|---:|---:|---:|---:|---:|---:|---:|")
        for c in members:
            out.append(f"| {LABELS[c]} | {gap(get(c, 'tick_gap_p50_ms'))} | {gap(get(c, 'tick_gap_p99_ms'))} | {f1(get(c, 'tick_gap_max_ms'))} | "
                       f"{f1(get(c, 'ack_p50_ms'))} | {f1(get(c, 'ack_p99_ms'))} | {f0(get(c, 'tick_advance_p50'))} | {f0(get(c, 'tick_advance_p99'))} |")
        out.append("\nOutcomes (whole run), resolvers left running (the drain, from the last send to the gauge at 0 for good, "
                   "has the profiler's 1 s resolution), and the server's memory:\n")
        out.append("| Cell | Applied | Failed | Timed out | Abandoned peak | Drain (ms, ±1000) | RSS peak (MB) |")
        out.append("|---|---:|---:|---:|---:|---:|---:|")
        for c in members:
            out.append(f"| {LABELS[c]} | {f0(get(c, 'applied'))} | {f0(get(c, 'failed'))} | {f0(get(c, 'timed_out'))} | "
                       f"{f0(get(c, 'abandoned_max'))} | {f0(get(c, 'drain_ms'))} | {f0(get(c, 'rss_mb_peak'))} |")
        if any(c in ("join10", "leave10") for c in members):
            out.append("\nJoin and leave checks against the seeded draws (counts over the run):\n")
            out.append("| Cell | Expected join failures | Expected leave failures | Leaves | Leaves dropped (server) |")
            out.append("|---|---:|---:|---:|---:|")
            for c in members:
                g = lambda k: median(runs, c, k, "counts")
                out.append(f"| {LABELS[c]} | {f0(g('expectedJoinFailures'))} | {f0(g('expectedLeaveFailures'))} | "
                           f"{f0(g('clientLeaves'))} | {f0(g('serverDroppedLeaves'))} |")
    return "\n".join(out)


def results_section(readme):
    marker = "## Results"
    if marker not in readme:
        sys.exit("README.md has no '## Results' section")
    body = readme.split(marker, 1)[1]
    nxt = body.find("\n## ")
    return body[:nxt] if nxt != -1 else body


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--markdown", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--results", type=pathlib.Path, default=RESULTS)
    args = ap.parse_args()
    runs = load(args.results)
    check(runs)
    md = tables(runs)
    if args.check:
        ok = results_section((TOPIC / "README.md").read_text()).strip() == md.strip()
        print("OK" if ok else "MISMATCH")
        sys.exit(0 if ok else 1)
    print(md)


if __name__ == "__main__":
    main()
