#!/usr/bin/env python3
"""Rebuild this topic's Results section from the reports under data/runs/.

  python3 regenerate.py          rewrite the Results section of README.md
  python3 regenerate.py --check  exit 1 if README.md's Results section is stale

Standard library only. Inputs:
  data/runs/<run>/report.json.gz   ws-loadtest reports, one per run
  data/host-cpu.json               host CPU summary per run (from summarize_host.py)

Run names: smoke-{A,B}, suite-{1,2,3}-{A,B}-{rooms}, prof-{A,B}-{rooms}, latency-{A,B}-{rooms}.
"""
import collections
import gzip
import json
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
README = HERE / "README.md"
START = "<!-- results start -->"
END = "<!-- results end -->"
BUILDS = ("A", "B")
ROOMS = (100, 300, 500, 1000)
SUITES = (1, 2, 3)
LATENCY_ROOMS = (100, 500, 1000)
FIT_ROOMS = (100, 300, 500)


def load(run):
    with gzip.open(HERE / "data" / "runs" / run / "report.json.gz", "rt") as f:
        return json.load(f)


def phase(report, name="steady"):
    return next(p for p in report["phases"] if p["name"] == name)


def by_phase(report, key, name="steady"):
    for entry in report.get(key) or []:
        if entry.get("phase") == name:
            return entry.get("summary")
    return None


NOT_CONNECTED = "JOIN_SESSION_NOT_CONNECTED"


def join_failures(p):
    """(count, {"error": n, "timeout": n, ...}) for one phase, from the client's per-reason counts.

    The per-failure records are capped (200 per phase), so the counts come from `byReason`. Every
    recorded error in this data carries JOIN_SESSION_NOT_CONNECTED; anything else stops the script.
    """
    failures = p["connectionLifecycle"]["joinFailures"]
    for record in p["connectionLifecycle"].get("joinFailureRecords") or []:
        if record.get("reason") == "error" and record.get("code") != NOT_CONNECTED:
            raise SystemExit(f"unexpected join error code {record.get('code')!r} in phase {p['name']}")
    return failures["phase"], collections.Counter(failures.get("byReason") or {})


def row(run, host):
    report = load(run)
    p = phase(report)
    m = p["measurement"]
    cpu = by_phase(report, "serverCpu")
    sync = by_phase(report, "serverSync")
    send = by_phase(report, "serverSend")
    failures, codes = join_failures(p)
    joined = (m.get("joined") or {}).get("atMeasuredStart")
    return {
        "run": run,
        "connections": p["connections"],
        "joined": joined,
        "rtt": p["rtt"],
        "update": p["update"],
        "cpuMean": cpu["meanPct"] if cpu else None,
        "cpuP95": cpu["p95Pct"] if cpu else None,
        "hostMean": (host.get(run) or {}).get("totalMeanPct"),
        "clientTotal": (m.get("clientCpu") or {}).get("totalPct"),
        "workerMax": ((m.get("clientCpu") or {}).get("perWorkerPct") or {}).get("max"),
        "loopP99Max": ((m.get("clientLoopDelay") or {}).get("p99Ms") or {}).get("max"),
        "disconnects": p["phaseTotals"]["disconnectCount"],
        "joinFailures": failures,
        "joinCodes": codes,
        "phasesPassed": "".join("P" if q["passed"] else "F" for q in report["phases"]),
        "sync": sync["totals"] if sync else None,
        "send": send,
        "i2v": m.get("inputToVisible"),
        "report": report,
    }


def f2(v):
    return "n/a" if v is None else f"{v:.2f}"


def f1(v):
    return "n/a" if v is None else f"{v:.1f}"


def fi(v):
    return "n/a" if v is None else f"{v:,}" if isinstance(v, int) else f"{v:g}"


def rng(values, fmt):
    values = [v for v in values if v is not None]
    if not values:
        return "n/a"
    return f"{fmt(statistics.median(values))} [{fmt(min(values))}–{fmt(max(values))}]"


def table(header, rows):
    out = ["| " + " | ".join(header) + " |", "|" + "|".join("---" for _ in header) + "|"]
    out += ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]
    return "\n".join(out)


def codes_cell(x):
    if not x["joinFailures"]:
        return "0"
    names = {"error": "NOT_CONNECTED", "timeout": "timeout"}
    parts = ", ".join(f"{names.get(reason, reason)} {n}" for reason, n in sorted(x["joinCodes"].items()))
    return f"{x['joinFailures']} ({parts})"


def build():
    host = json.loads((HERE / "data" / "host-cpu.json").read_text())
    runs = {d.name: row(d.name, host) for d in sorted((HERE / "data" / "runs").iterdir())}
    suite = {(b, r): [runs[f"suite-{s}-{b}-{r}"] for s in SUITES] for b in BUILDS for r in ROOMS}
    parts = []

    # Step 1.
    rows = []
    for b in BUILDS:
        x = runs[f"smoke-{b}"]
        rows.append([b, 100, f"{x['joined']} / {x['connections']}",
                     f"{f2(x['rtt']['p50'])} / {f2(x['rtt']['p95'])} / {f2(x['rtt']['p99'])}",
                     f"{f1(x['cpuMean'])} / {f1(x['cpuP95'])}", x["disconnects"], codes_cell(x), x["phasesPassed"]])
    parts.append("### Step 1: smoke, 100 rooms, steady phase\n\n" + table(
        ["build", "rooms", "joined / connections", "RTT p50 / p95 / p99 (ms)", "server CPU mean / p95 (%)",
         "disconnects", "join failures (by code)", "phases passed (pre / steady / post)"], rows))

    # Step 2, each run.
    rows = []
    for s in SUITES:
        for b in BUILDS:
            for r in ROOMS:
                x = runs[f"suite-{s}-{b}-{r}"]
                rows.append([s, b, r, f"{x['joined']} / {x['connections']}",
                             f"{f2(x['rtt']['p50'])} / {f2(x['rtt']['p95'])} / {f2(x['rtt']['p99'])}",
                             f"{x['update']['p95']} / {x['update']['p99']}",
                             f"{f1(x['cpuMean'])} / {f1(x['cpuP95'])}", f1(x["hostMean"]), f1(x["clientTotal"]),
                             x["disconnects"], codes_cell(x), x["phasesPassed"]])
    parts.append("### Step 2: matrix, steady phase, each run (unprofiled)\n\n" + table(
        ["suite", "build", "rooms", "joined at measured start / connections", "RTT p50 / p95 / p99 (ms)",
         "update p95 / p99 (ms)", "server CPU mean / p95 (%, 100 = 1 core)", "host CPU mean (% of machine)",
         "client CPU total (% of 1 core)", "disconnects", "join failures (by code)",
         "phases passed (pre / steady / post)"], rows))

    # Step 2, per room count and build.
    rows = []
    for r in ROOMS:
        for b in BUILDS:
            xs = suite[(b, r)]
            rows.append([r, b, rng([x["joined"] for x in xs], fi),
                         rng([x["rtt"]["p50"] for x in xs], f2), rng([x["rtt"]["p99"] for x in xs], f2),
                         rng([x["update"]["p99"] for x in xs], fi),
                         rng([x["cpuMean"] for x in xs], f1),
                         rng([x["cpuMean"] * 1000 / x["joined"] for x in xs], f1),
                         rng([x["hostMean"] for x in xs], f1),
                         sum(x["joinFailures"] for x in xs), sum(x["disconnects"] for x in xs)])
    parts.append("### Step 2 per room count and build: median [min–max] over the 3 suites\n\n" + table(
        ["rooms", "build", "joined at measured start", "RTT p50 (ms)", "RTT p99 (ms)", "update p99 (ms)",
         "server CPU mean (%)", "server CPU per 1000 joined players (%)", "host CPU mean (%)",
         "join failures (sum)", "disconnects (sum)"], rows))

    # B - A.
    rows = []
    for r in ROOMS:
        a = statistics.median(x["cpuMean"] for x in suite[("A", r)])
        b = statistics.median(x["cpuMean"] for x in suite[("B", r)])
        paired = [suite[("B", r)][i]["cpuMean"] - suite[("A", r)][i]["cpuMean"] for i in range(len(SUITES))]
        rows.append([r, f1(a), f1(b), f"{b - a:+.1f}", f"{(b - a) * 100 / a:+.1f} %",
                     ", ".join(f"{d:+.1f}" for d in paired)])
    parts.append("### Server CPU, B − A (step 2)\n\n" + table(
        ["rooms", "A median (%)", "B median (%)", "B − A (points)", "B − A (relative)",
         "per-suite B − A, suites 1 / 2 / 3 (points)"], rows))

    # Cost per player.
    rows = []
    fits = {}
    for b in BUILDS:
        pts = [(statistics.median(x["joined"] for x in suite[(b, r)]),
                statistics.median(x["cpuMean"] for x in suite[(b, r)])) for r in ROOMS]
        marginal = [(pts[i + 1][1] - pts[i][1]) * 1000 / (pts[i + 1][0] - pts[i][0]) for i in range(len(pts) - 1)]
        xs = [pt[0] for pt in pts[:len(FIT_ROOMS)]]
        ys = [pt[1] for pt in pts[:len(FIT_ROOMS)]]
        mx, my = statistics.mean(xs), statistics.mean(ys)
        slope = sum((u - mx) * (v - my) for u, v in zip(xs, ys)) / sum((u - mx) ** 2 for u in xs)
        intercept = my - slope * mx
        predicted = intercept + slope * pts[-1][0]
        fits[b] = (intercept, slope)
        rows.append([b, " / ".join(f1(v) for v in marginal), f1(intercept), f1(slope * 1000),
                     f1(predicted), f1(pts[-1][1]), f"{pts[-1][1] - predicted:+.1f}"])
    (ia, sa), (ib, sb) = fits["A"], fits["B"]
    cross = (ia - ib) / (sb - sa)
    parts.append("### Server CPU against joined players (step 2 medians)\n\n" + table(
        ["build", "marginal CPU per 1000 players: 100→300 / 300→500 / 500→1000 rooms (%)",
         "fit over 100–500 rooms: intercept (%)", "fit: slope per 1000 players (%)",
         "fit's value at 1000 rooms (%)", "measured at 1000 rooms (%)", "measured − fit (points)"], rows)
        + f"\n\nThe two fitted lines cross at {cross:,.0f} joined players. "
        f"The slope difference, {(sb - sa) * 1000:.1f} points per 1000 players, is "
        f"{(sb - sa) / 100 / 10 * 1e6:.1f} µs of CPU per state frame at 10 frames per player per second.")

    # Step 3.
    rows = []
    for b in BUILDS:
        for r in ROOMS:
            x = runs[f"prof-{b}-{r}"]
            sync, send = x["sync"], x["send"]
            folds = f"{sync['syncFolds'] / sync['syncCycles']:.3f}" if sync and sync["syncCycles"] else "n/a"
            send_cell = ("n/a" if not send else
                         f"{send['bufferedBytesMax']} / {send['unwritableEpisodes']} / {send['unwritableLongestMs']} / "
                         f"{send.get('backlogCloses')}")
            rows.append([b, r, f"{x['joined']} / {x['connections']}",
                         f"{f2(x['rtt']['p50'])} / {f2(x['rtt']['p95'])} / {f2(x['rtt']['p99'])}",
                         f"{f1(x['cpuMean'])} / {f1(x['cpuP95'])}",
                         fi(sync["syncCycles"]) if sync else "n/a", folds, send_cell,
                         x["disconnects"], codes_cell(x)])
    parts.append("### Step 3: one profiled suite per build, steady phase\n\n" + table(
        ["build", "rooms", "joined / connections", "RTT p50 / p95 / p99 (ms)", "server CPU mean / p95 (%)",
         "sync cycles", "folds / cycles", "send: buffered bytes max / unwritable episodes / longest (ms) / backlog closes",
         "disconnects", "join failures (by code)"], rows))

    # Step 4.
    rows = []
    for r in LATENCY_ROOMS:
        for b in BUILDS:
            x = runs[f"latency-{b}-{r}"]
            i2v = x["i2v"]
            lat = i2v["latencyMs"]
            rows.append([r, b, f"{x['joined']} / {x['connections']}",
                         f"{lat['p50']} / {lat['p95']} / {lat['p99']} / {lat['max']}",
                         f"{i2v['sent']:,} / {i2v['seen']:,} / {i2v['superseded']:,} / {i2v['timedOut']:,}",
                         f"{f2(x['rtt']['p50'])} / {f2(x['rtt']['p95'])} / {f2(x['rtt']['p99'])}",
                         f"{x['update']['p95']} / {x['update']['p99']}",
                         f"{f1(x['cpuMean'])} / {f1(x['cpuP95'])}",
                         f"{f1(x['clientTotal'])} / {f1(x['workerMax'])} / {f2(x['loopP99Max'])}",
                         x["disconnects"], codes_cell(x)])
    parts.append("### Step 4: input-to-visible latency, MoveTo at 2/s per player, steady phase (unprofiled)\n\n" + table(
        ["rooms", "build", "joined / connections", "input-to-visible p50 / p95 / p99 / max (ms)",
         "sent / seen / superseded / timed out", "RTT p50 / p95 / p99 (ms)", "update p95 / p99 (ms)",
         "server CPU mean / p95 (%)", "client CPU total / worst worker (%) / worst loop delay p99 (ms)",
         "disconnects", "join failures (by code)"], rows))

    # Join failures, A, every phase.
    rows = []
    for name in sorted(runs):
        if "-A" not in name and name != "smoke-A":
            continue
        cells = []
        for q in runs[name]["report"]["phases"]:
            n, codes = join_failures(q)
            nc = codes.get("error", 0)
            to = codes.get("timeout", 0)
            other = n - nc - to
            cells.append(f"{nc} / {to}" + (f" / other {other}" if other else ""))
        rows.append([name] + cells)
    parts.append("### Build A's join failures by phase: JOIN_SESSION_NOT_CONNECTED / timeout (no response in 5 s)\n\n"
                 + table(["run", "preflight", "steady", "postflight"], rows)
                 + "\n\nBuild B had no join failure in any phase of any run.")
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
