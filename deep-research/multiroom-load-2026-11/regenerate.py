#!/usr/bin/env python3
"""Rebuild this topic's Results section from the reports under data/ and the 2026-02-06 suite.

  python3 regenerate.py          rewrite the Results section of README.md
  python3 regenerate.py --check  exit 1 if README.md's Results section is stale

Standard library only. Inputs:
  data/rerun/<run>/report.json.gz   the 2026-11-06 runs (ws-loadtest reports)
  data/host-cpu.json                host CPU summary per run (from summarize_host.py)
  data/b0/<run>/report.json.gz      the 2026-11-05 comparison runs
  ../multiroom-load-2026-02/evidence-2026-02-06-nio-stage3-100-300-500/scalability-2026-02-06T14-24-28/
"""
import gzip
import json
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
README = HERE / "README.md"
START = "<!-- results start -->"
END = "<!-- results end -->"
FEB = HERE.parent / "multiroom-load-2026-02" / "evidence-2026-02-06-nio-stage3-100-300-500" / "scalability-2026-02-06T14-24-28"
ROOMS = (100, 300, 500)
SUITES = (1, 2, 3)


def load_gz(path):
    with gzip.open(path, "rt") as f:
        return json.load(f)


def phase(report, name="steady"):
    return next(p for p in report["phases"] if p["name"] == name)


def by_phase(report, key, name="steady"):
    """The per-phase summary of a top-level server section, or None."""
    for entry in report.get(key) or []:
        if entry.get("phase") == name:
            return entry.get("summary")
    return None


def steady_row(report, host=None):
    p = phase(report)
    m = p.get("measurement", {})
    lifecycle = p.get("connectionLifecycle", {})
    layout = p.get("layout") or {}
    cpu = by_phase(report, "serverCpu")
    sync = by_phase(report, "serverSync")
    send = by_phase(report, "serverSend")
    client = m.get("clientCpu") or {}
    loop = m.get("clientLoopDelay") or {}
    totals = p.get("phaseTotals") or {}
    return {
        "connections": p["connections"],
        "lands": layout.get("lands"),
        "rtt": p["rtt"],
        "update": p["update"],
        "disconnects": totals.get("disconnectCount"),
        "disconnectRate": p.get("disconnectRate"),
        "errors": totals.get("errorCount"),
        "joinFailures": (lifecycle.get("joinFailures") or {}).get("phase"),
        "passed": p["passed"],
        "cpuMean": cpu["meanPct"] if cpu else None,
        "cpuP95": cpu["p95Pct"] if cpu else None,
        "hostMean": host["totalMeanPct"] if host else None,
        "hostP95": host["totalP95Pct"] if host else None,
        "clientTotal": client.get("totalPct"),
        "workerMax": (client.get("perWorkerPct") or {}).get("max"),
        "loopP99Max": (loop.get("p99Ms") or {}).get("max"),
        "syncCycles": sync["totals"]["syncCycles"] if sync else None,
        "syncFolds": sync["totals"]["syncFolds"] if sync else None,
        "syncOverdueFolds": sync["totals"]["syncOverdueFolds"] if sync else None,
        "syncSkips": (sync["totals"]["syncSkipsBacklog"] + sync["totals"]["syncSkipsBusy"]) if sync else None,
        "bufMax": send["bufferedBytesMax"] if send else None,
        "episodes": send["unwritableEpisodes"] if send else None,
        "longestMs": send["unwritableLongestMs"] if send else None,
        "backlogCloses": send.get("backlogCloses") if send else None,
    }


def f2(v):
    """Two decimals; an integer stays one (the 2026-02-06 client recorded whole ms)."""
    if v is None:
        return "n/a"
    return str(v) if isinstance(v, int) else f"{v:.2f}"


def f1(v):
    return "n/a" if v is None else f"{v:.1f}"


def fi(v):
    return "n/a" if v is None else f"{v:,}" if isinstance(v, int) else f"{v:g}"


def rng(values, fmt):
    values = [v for v in values if v is not None]
    if not values:
        return "n/a"
    med = statistics.median(values)
    return f"{fmt(med)} [{fmt(min(values))}–{fmt(max(values))}]"


def table(header, rows):
    out = ["| " + " | ".join(header) + " |", "|" + "|".join("---" for _ in header) + "|"]
    out += ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]
    return "\n".join(out)


def build():
    host = json.loads((HERE / "data" / "host-cpu.json").read_text())
    runs = {}
    for d in sorted((HERE / "data" / "rerun").iterdir()):
        runs[d.name] = steady_row(load_gz(d / "report.json.gz"), host.get(d.name))
    b0 = {}
    for d in sorted((HERE / "data" / "b0").iterdir()):
        b0[d.name] = steady_row(load_gz(d / "report.json.gz"))
    feb = {}
    summary = json.loads((FEB / "summary.json").read_text())
    for run in summary["runs"]:
        report_path = next((FEB / f"run-{run['runIndex']}").glob("ws-loadtest-*.json"))
        feb[run["rooms"]] = steady_row(json.loads(report_path.read_text()))

    parts = []
    # Per run.
    rows = []
    for s in SUITES:
        for r in ROOMS:
            x = runs[f"rerun-suite-{s}-{r}"]
            rows.append([s, r, fi(x["connections"]), fi(x["lands"]),
                         f"{f2(x['rtt']['p50'])} / {f2(x['rtt']['p95'])} / {f2(x['rtt']['p99'])}",
                         f"{x['update']['p50']} / {x['update']['p95']} / {x['update']['p99']}",
                         f"{f1(x['cpuMean'])} / {f1(x['cpuP95'])}",
                         f"{f1(x['hostMean'])} / {fi(x['hostP95'])}",
                         f"{f1(x['clientTotal'])} / {f1(x['workerMax'])}",
                         f2(x["loopP99Max"]),
                         f"{x['disconnects']} / {x['joinFailures']} / {x['errors']}",
                         "pass" if x["passed"] else "FAIL"])
    parts.append("### Steady phase, each run\n\n" + table(
        ["suite", "rooms", "connections", "lands", "RTT p50 / p95 / p99 (ms)", "update interval p50 / p95 / p99 (ms)",
         "server CPU mean / p95 (%, 100 = 1 core)", "host CPU mean / p95 (% of machine)",
         "client CPU total / worst worker (% of 1 core)", "worst worker loop delay p99 (ms)",
         "disconnects / join failures / errors", "phase"], rows))

    rows = []
    for s in SUITES:
        for r in ROOMS:
            x = runs[f"rerun-suite-{s}-{r}"]
            folds = x["syncFolds"] / x["syncCycles"] if x["syncCycles"] else None
            overdue = x["syncOverdueFolds"] * 1000 / x["syncCycles"] if x["syncCycles"] else None
            rows.append([s, r, fi(x["syncCycles"]), fi(x["syncSkips"]), f"{folds:.3f}" if folds is not None else "n/a",
                         f"{overdue:.0f}" if overdue is not None else "n/a",
                         fi(x["bufMax"]), fi(x["episodes"]), fi(x["longestMs"]), fi(x["backlogCloses"])])
    parts.append("### Server counters, steady phase, each run\n\n" + table(
        ["suite", "rooms", "sync cycles", "sync skips (backlog + busy)", "folds / cycles",
         "overdue folds per 1000 cycles (scheduler race, see Caveats)", "send buffered bytes max",
         "unwritable episodes", "longest unwritable (ms)", "backlog closes (4008)"], rows))

    # Per room count across suites.
    rows = []
    for r in ROOMS:
        xs = [runs[f"rerun-suite-{s}-{r}"] for s in SUITES]
        rows.append([r, len(xs),
                     rng([x["rtt"]["p50"] for x in xs], f2), rng([x["rtt"]["p99"] for x in xs], f2),
                     rng([x["update"]["p95"] for x in xs], fi), rng([x["update"]["p99"] for x in xs], fi),
                     rng([x["cpuMean"] for x in xs], f1), rng([x["hostMean"] for x in xs], f1),
                     sum(x["disconnects"] for x in xs)])
    parts.append("### Steady phase per room count: median [min–max] over the 3 suites\n\n" + table(
        ["rooms", "runs", "RTT p50 (ms)", "RTT p99 (ms)", "update p95 (ms)", "update p99 (ms)",
         "server CPU mean (%)", "host CPU mean (%)", "disconnects (sum)"], rows))

    # Profiler overhead pair.
    on, off = runs["overhead-profiled"], runs["overhead-unprofiled"]
    rows = []
    for label, a, b, fmt in (("RTT p50 (ms)", on["rtt"]["p50"], off["rtt"]["p50"], f2),
                             ("RTT p95 (ms)", on["rtt"]["p95"], off["rtt"]["p95"], f2),
                             ("RTT p99 (ms)", on["rtt"]["p99"], off["rtt"]["p99"], f2),
                             ("server CPU mean (%)", on["cpuMean"], off["cpuMean"], f1)):
        rows.append([label, fmt(a), fmt(b), fmt(a - b), f"{(a - b) * 100 / b:.1f} %"])
    parts.append("### Profiler overhead, 500 rooms, back to back\n\n" + table(
        ["steady phase", "profiled", "unprofiled", "difference", "relative"], rows)
        + f"\n\nBoth runs: {on['disconnects']} and {off['disconnects']} disconnects.")

    # Comparison.
    rows = []
    for r in ROOMS:
        xs = [runs[f"rerun-suite-{s}-{r}"] for s in SUITES]
        bs = [b0[k] for k in sorted(b0) if k.startswith(f"r{r}-")]
        fb = feb.get(r)

        def col(pick, fmt, items):
            return rng([pick(x) for x in items], fmt) if items else "not run"

        for label, pick, fmt in (
            ("connections", lambda x: x["connections"], fi),
            ("lands", lambda x: x["lands"], fi),
            ("RTT p50 (ms)", lambda x: x["rtt"]["p50"], f2),
            ("RTT p95 (ms)", lambda x: x["rtt"]["p95"], f2),
            ("RTT p99 (ms)", lambda x: x["rtt"]["p99"], f2),
            ("update p50 (ms)", lambda x: x["update"]["p50"], fi),
            ("update p95 (ms)", lambda x: x["update"]["p95"], fi),
            ("update p99 (ms)", lambda x: x["update"]["p99"], fi),
            ("server CPU mean (%)", lambda x: x["cpuMean"], f1),
            ("disconnect rate", lambda x: x["disconnectRate"], fi),
        ):
            feb_value = "n/a"
            if fb is not None:
                v = pick(fb)
                if label == "lands":
                    v = fb["connections"]  # one land per connection (legacy client)
                feb_value = fmt(v) if v is not None else "n/a"
            rows.append([r, label, col(pick, fmt, xs), col(pick, fmt, bs), feb_value])
    parts.append("### Comparison: this rerun, 2026-11-05 comparison runs, 2026-02-06 suite\n\n"
                 "This rerun and the 2026-11-05 runs: median [min–max] over 3 runs. 2026-02-06: one run per room count. "
                 "Read the column caveats below before comparing.\n\n" + table(
                     ["rooms", "steady phase", "2026-11-06 (this rerun)", "2026-11-05", "2026-02-06"], rows))
    return "\n\n".join(parts) + "\n"


def main():
    text = README.read_text()
    head, rest = text.split(START, 1)
    _, tail = rest.split(END, 1)
    new = f"{head}{START}\n\n{build()}\n{END}{tail}"
    if "--check" in sys.argv:
        if new != text:
            print("README.md Results are stale: run python3 regenerate.py", file=sys.stderr)
            sys.exit(1)
        print("README.md Results are current.")
        return
    README.write_text(new)


if __name__ == "__main__":
    main()
