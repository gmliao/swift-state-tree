#!/usr/bin/env python3
"""Rebuild this topic's generated sections from the data under data/.

  python3 regenerate.py          rewrite the Results and the diagnosis sections of README.md
  python3 regenerate.py --check  exit 1 if either section of README.md is stale

Standard library only. Inputs:
  data/runs/<run>/report.json.gz   ws-loadtest reports, one per run
  data/host-cpu.json               host CPU summary per run (from summarize_host.py)
  data/diag-ctx.json               server context switches per diagnosis run (from summarize_ctx.py)
  data/provenance/diag/chain/      the diagnosis runs' headers (start time) and chain log

Run names, A/B steps: smoke-{A,B}, suite-{1,2,3}-{A,B}-{rooms}, prof-{A,B}-{rooms},
latency-{A,B}-{rooms}. Diagnosis (all build B): diag-{1,2,3}-{D,T12,L}-{100,1000},
diag-p{100,1000}-{1,2,3}-{P,D}, diag-lat-{1..4}-{D,L}-1000, diag-plat-{1,2}-{P,D},
diag-ctx-{D,T12}-1000, diag-prof-{D,L}-{100,1000}, diag-profLat-{D,L}-1000.
"""
import collections
import gzip
import json
import re
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
README = HERE / "README.md"
START = "<!-- results start -->"
END = "<!-- results end -->"
DIAG_START = "<!-- diagnosis start -->"
DIAG_END = "<!-- diagnosis end -->"
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
    runs = {d.name: row(d.name, host) for d in sorted((HERE / "data" / "runs").iterdir())
            if not d.name.startswith("diag-")}
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


# ---------------------------------------------------------------------------------------------
# Diagnosis of B's per-player cost (all runs on build B).

DIAG_CONFIGS = ("D", "T12", "L")
DIAG_ROOMS = (100, 1000)
PAIRS = (1, 2, 3)
PHASES = ("preflight", "steady", "postflight")


def claim(condition, text):
    """A sentence of the findings that states a property of the data; stale data fails the build."""
    if not condition:
        raise SystemExit(f"diagnosis claim no longer holds: {text}")
    return text


def pct(new, base):
    return (new - base) * 100 / base


def sign1(v):
    return f"{v:+.1f}"


def signp(v):
    return f"{v:+.1f} %"


def run_start(run):
    header = (HERE / "data" / "provenance" / "diag" / "chain" / f"{run}.run-header.txt").read_text()
    return re.search(r"^start=(\S+)", header, re.M).group(1)


def phase_sync(report, name):
    s = by_phase(report, "serverSync", name)
    return s["totals"] if s else None


def build_diagnosis():
    host = json.loads((HERE / "data" / "host-cpu.json").read_text())
    ctx = json.loads((HERE / "data" / "diag-ctx.json").read_text())
    names = sorted(d.name for d in (HERE / "data" / "runs").iterdir() if d.name.startswith("diag-"))
    runs = {n: row(n, host) for n in names}
    for n in names:
        runs[n]["hostP95"] = (host.get(n) or {}).get("totalP95Pct")
        runs[n]["start"] = run_start(n)
    matrix = {(c, r): [runs[f"diag-{s}-{c}-{r}"] for s in SUITES] for c in DIAG_CONFIGS for r in DIAG_ROOMS}
    pairs = {(cfg, r): [runs[f"diag-p{r}-{i}-{cfg}"] for i in PAIRS] for cfg in ("P", "D") for r in DIAG_ROOMS}
    parts = []

    # Run log.
    chain = (HERE / "data" / "provenance" / "diag" / "chain" / "chain.log").read_text()
    starts = re.findall(r"^\S+ (diag-\S+) start cfg=\S+ env=\[[^\]]*\]: TIME_WAIT=(\d+) waited=(\d+)s", chain, re.M)
    assert sorted(s[0] for s in starts) == names, "chain.log and data/runs disagree on the diagnosis runs"
    tw = [int(s[1]) for s in starts]
    waits = [int(s[2]) for s in starts]
    every = [runs[n] for n in names]
    first, last = min(x["start"] for x in every), max(x["start"] for x in every)
    disconnects = sum(q["phaseTotals"]["disconnectCount"] for x in every for q in x["report"]["phases"])
    failures = sum(join_failures(q)[0] for x in every for q in x["report"]["phases"])
    parts.append(
        f"{len(names)} runs, started {first[11:16]}–{last[11:16]} UTC on {first[:10]}; "
        f"{disconnects} disconnects and {failures} join failures over all phases of all of them. "
        f"TIME_WAIT at each start was {min(tw)}–{max(tw)}, after waits of {min(waits)}–{max(waits)} s.")

    # Matrix, each run.
    rows = []
    for s in SUITES:
        order = sorted((runs[f"diag-{s}-{c}-100"]["start"], c) for c in DIAG_CONFIGS)
        for _, c in order:
            for r in DIAG_ROOMS:
                x = runs[f"diag-{s}-{c}-{r}"]
                rows.append([s, c, r, x["start"][11:16], f"{x['joined']} / {x['connections']}",
                             f"{f2(x['rtt']['p50'])} / {f2(x['rtt']['p95'])} / {f2(x['rtt']['p99'])}",
                             f"{x['update']['p95']} / {x['update']['p99']}",
                             f"{f1(x['cpuMean'])} / {f1(x['cpuP95'])}",
                             f"{f1(x['hostMean'])} / {fi(x['hostP95'])}",
                             x["disconnects"], codes_cell(x)])
    parts.append("### D1. Matrix: D, T12, L × 100 / 1000 rooms × 3 suites, steady phase, each run (unprofiled)\n\n" + table(
        ["suite", "config", "rooms", "start (UTC)", "joined / connections", "RTT p50 / p95 / p99 (ms)",
         "update p95 / p99 (ms)", "server CPU mean / p95 (%, 100 = 1 core)", "host CPU mean / p95 (% of machine)",
         "disconnects", "join failures"], rows))

    # Matrix, medians.
    rows = []
    for r in DIAG_ROOMS:
        for c in DIAG_CONFIGS:
            xs = matrix[(c, r)]
            rows.append([r, c, rng([x["rtt"]["p50"] for x in xs], f2), rng([x["rtt"]["p99"] for x in xs], f2),
                         rng([x["update"]["p99"] for x in xs], fi), rng([x["cpuMean"] for x in xs], f1),
                         rng([x["cpuP95"] for x in xs], f1), rng([x["hostMean"] for x in xs], f1)])
    parts.append("### D2. Matrix per room count and config: median [min–max] over the 3 suites\n\n" + table(
        ["rooms", "config", "RTT p50 (ms)", "RTT p99 (ms)", "update p99 (ms)", "server CPU mean (%)",
         "server CPU p95 (%)", "host CPU mean (%)"], rows))

    # Matrix, against D.
    rows = []
    med = {k: statistics.median(x["cpuMean"] for x in v) for k, v in matrix.items()}
    for r in DIAG_ROOMS:
        d = [x["cpuMean"] for x in matrix[("D", r)]]
        for c in ("T12", "L"):
            per_suite = [matrix[(c, r)][i]["cpuMean"] - d[i] for i in range(len(SUITES))]
            ratio = [matrix[(c, r)][i]["rtt"]["p99"] / matrix[("D", r)][i]["rtt"]["p99"] for i in range(len(SUITES))]
            rows.append([r, c, sign1(med[(c, r)] - med[("D", r)]), signp(pct(med[(c, r)], med[("D", r)])),
                         ", ".join(sign1(v) for v in per_suite), f"{max(d) - min(d):.1f}",
                         ", ".join(f"{v:.1f}×" for v in ratio)])
    parts.append("### D3. Matrix against D: server CPU and RTT p99\n\n" + table(
        ["rooms", "config", "CPU, median − D's median (points)", "relative", "per-suite config − D, suites 1 / 2 / 3 (points)",
         "D's own CPU range over the 3 suites (points)", "RTT p99, config / D per suite, suites 1 / 2 / 3"], rows)
        + "\n\nSuites are aligned by number. The configs ran in a different order in each suite (D1).")

    # P/D pairs.
    rows = []
    for r in DIAG_ROOMS:
        for i in PAIRS:
            for cfg in ("P", "D"):
                x = runs[f"diag-p{r}-{i}-{cfg}"]
                rows.append([r, i, cfg, x["start"][11:16], f"{x['joined']} / {x['connections']}",
                             f"{f2(x['rtt']['p50'])} / {f2(x['rtt']['p95'])} / {f2(x['rtt']['p99'])}",
                             f"{x['update']['p95']} / {x['update']['p99']}",
                             f"{f1(x['cpuMean'])} / {f1(x['cpuP95'])}", f"{f1(x['hostMean'])} / {fi(x['hostP95'])}",
                             x["disconnects"], codes_cell(x)])
    parts.append("### D4. P / D pairs, steady phase, each run (unprofiled; P ran first in each pair)\n\n" + table(
        ["rooms", "pair", "config", "start (UTC)", "joined / connections", "RTT p50 / p95 / p99 (ms)",
         "update p95 / p99 (ms)", "server CPU mean / p95 (%)", "host CPU mean / p95 (%)", "disconnects",
         "join failures"], rows))
    rows = []
    pd = {}
    for r in DIAG_ROOMS:
        p, d = pairs[("P", r)], pairs[("D", r)]
        cpu = [p[i]["cpuMean"] - d[i]["cpuMean"] for i in range(3)]
        p50 = [p[i]["rtt"]["p50"] - d[i]["rtt"]["p50"] for i in range(3)]
        p99 = [p[i]["rtt"]["p99"] - d[i]["rtt"]["p99"] for i in range(3)]
        u99 = [p[i]["update"]["p99"] - d[i]["update"]["p99"] for i in range(3)]
        pd[r] = (cpu, p50, p99, u99)
        mdd = statistics.median(x["cpuMean"] for x in d)
        rows.append([r, ", ".join(sign1(v) for v in cpu),
                     f"{sign1(statistics.median(cpu))} ({signp(statistics.median(cpu) * 100 / mdd)} of D's median)",
                     ", ".join(f"{v:+.2f}" for v in p50), ", ".join(f"{v:+.2f}" for v in p99),
                     ", ".join(f"{v:+d}" for v in u99)])
    parts.append("### D5. P − D per pair (pairs 1 / 2 / 3)\n\n" + table(
        ["rooms", "server CPU (points)", "median of the pair differences", "RTT p50 (ms)", "RTT p99 (ms)",
         "update p99 (ms)"], rows))

    # MoveTo at 2/s.
    lat_runs = [n for n in names if n.startswith(("diag-lat-", "diag-plat-"))]
    lat_runs.sort(key=lambda n: runs[n]["start"])
    rows = []
    for n in lat_runs:
        x = runs[n]
        i2v, cfg = x["i2v"], n.rsplit("-", 2)[1] if n.startswith("diag-lat-") else n.rsplit("-", 1)[1]
        x["cfg"] = cfg
        lat = i2v["latencyMs"]
        rows.append([n, cfg, x["start"][11:16], f"{x['joined']} / {x['connections']}",
                     f"{lat['p50']} / {lat['p95']} / {lat['p99']} / {lat['max']}",
                     f"{i2v['sent']:,} / {i2v['seen']:,} / {i2v['superseded']:,} / {i2v['timedOut']:,}",
                     f"{f2(x['rtt']['p50'])} / {f2(x['rtt']['p95'])} / {f2(x['rtt']['p99'])}",
                     f"{x['update']['p95']} / {x['update']['p99']}",
                     f"{f1(x['cpuMean'])} / {f1(x['cpuP95'])}",
                     f"{f1(x['clientTotal'])} / {f1(x['workerMax'])} / {f2(x['loopP99Max'])}",
                     x["disconnects"], codes_cell(x)])
    parts.append("### D6. MoveTo at 2/s per player, 1000 rooms, steady phase, each run (unprofiled)\n\n" + table(
        ["run", "config", "start (UTC)", "joined / connections", "input-to-visible p50 / p95 / p99 / max (ms)",
         "sent / seen / superseded / timed out", "RTT p50 / p95 / p99 (ms)", "update p95 / p99 (ms)",
         "server CPU mean / p95 (%)", "client CPU total / worst worker (%) / worst loop delay p99 (ms)",
         "disconnects", "join failures"], rows))

    # Profiled D/L.
    prof_runs = ["diag-prof-D-100", "diag-prof-L-100", "diag-prof-D-1000", "diag-prof-L-1000",
                 "diag-profLat-D-1000", "diag-profLat-L-1000"]
    rows = []
    for n in prof_runs:
        x = runs[n]
        for ph in PHASES:
            t = phase_sync(x["report"], ph)
            q = phase(x["report"], ph)
            cpu = by_phase(x["report"], "serverCpu", ph)
            rows.append([n, ph, fi(t["syncCycles"]), fi(t["syncSkipsBusy"]), fi(t["syncSkipsBacklog"]),
                         fi(t["syncDeferredTurns"]), fi(t["syncFolds"]), fi(t["syncOverdueFolds"]),
                         f2(q["rtt"]["p99"]), q["update"]["p99"], f1(cpu["meanPct"])])
    parts.append("### D7. Profiled D and L: sync counters per phase\n\n" + table(
        ["run", "phase", "sync cycles", "skips: busy", "skips: backlog", "deferred turns", "folds",
         "folds past deadline (loop race)", "RTT p99 (ms)", "update p99 (ms)", "server CPU mean (%)"], rows)
        + "\n\n`diag-profLat-*` add MoveTo at 2/s, as in D6. Sync counters are summed over all lands "
        "(METRICS.md); this build has no late-fold counter.")

    # Context switches.
    rows = []
    for n in sorted(ctx, key=lambda k: runs[k]["start"]):
        c, x = ctx[n], runs[n]
        a, w = c["allThreads"], c["wholeWindow"]
        rows.append([n, "yes" if n.startswith("diag-prof") else "no",
                     "MoveTo 2/s" if x["i2v"] else "actions only",
                     c["windowSeconds"], c["samples"],
                     f"{a['threads']} / {a['voluntaryPerSecond']:,} / {a['nonvoluntaryPerSecond']:,}",
                     f"{w['threads']} / {w['voluntaryPerSecond']:,} / {w['nonvoluntaryPerSecond']:,}",
                     f1(x["cpuMean"])])
    parts.append("### D8. Server context switches per second, steady measured window\n\n" + table(
        ["run", "profiled", "workload", "window (s)", "samples", "all threads seen: threads / voluntary / non-voluntary",
         "threads present for the whole window: threads / voluntary / non-voluntary", "server CPU mean (%)"], rows)
        + "\n\nCounts from /proc, once per second, for the whole GameServer process (`summarize_ctx.py`). "
        "The two columns differ by the threads the process creates inside the window.")

    def vol(run, kind):
        return ctx[run][kind]["voluntaryPerSecond"]

    def vol_diffs(pairs_):
        return {kind: [pct(vol(a, kind), vol(b, kind)) for a, b in pairs_] for kind in ("allThreads", "wholeWindow")}

    rows = []
    comparisons = [
        ("P − D", "1000, actions only", [(f"diag-p1000-{i}-P", f"diag-p1000-{i}-D") for i in PAIRS]),
        ("P − D", "100, actions only", [(f"diag-p100-{i}-P", f"diag-p100-{i}-D") for i in PAIRS]),
        ("P − D", "1000, MoveTo 2/s", [(f"diag-plat-{i}-P", f"diag-plat-{i}-D") for i in (1, 2)]),
        ("L − D", "100, profiled", [("diag-prof-L-100", "diag-prof-D-100")]),
        ("L − D", "1000, profiled", [("diag-prof-L-1000", "diag-prof-D-1000")]),
        ("L − D", "1000, profiled, MoveTo 2/s", [("diag-profLat-L-1000", "diag-profLat-D-1000")]),
        ("T12 − D", "1000, actions only", [("diag-ctx-T12-1000", "diag-ctx-D-1000")]),
    ]
    ctx_cmp = {}
    for what, where, prs in comparisons:
        dd = vol_diffs(prs)
        ctx_cmp[(what, where)] = dd
        rows.append([what, where, len(prs), ", ".join(signp(v) for v in dd["allThreads"]),
                     ", ".join(signp(v) for v in dd["wholeWindow"])])
    parts.append("### D9. Voluntary context switches against D (relative, per pair)\n\n" + table(
        ["comparison", "rooms, workload", "n (pairs)", "all threads seen", "threads present for the whole window"], rows))

    # Findings, every number computed above.
    ab = {}
    for b in BUILDS:
        ab[b] = statistics.median(row(f"suite-{s}-{b}-1000", host)["cpuMean"] for s in SUITES)
    ab_rel = pct(ab["B"], ab["A"])
    d1000 = [x["cpuMean"] for x in matrix[("D", 1000)]]
    d_range = max(d1000) - min(d1000)
    t12_rel, l_rel = pct(med[("T12", 1000)], med[("D", 1000)]), pct(med[("L", 1000)], med[("D", 1000)])
    t12_pts, l_pts = med[("T12", 1000)] - med[("D", 1000)], med[("L", 1000)] - med[("D", 1000)]
    cpu_p, _, p99_p, u99_p = pd[1000]
    p_med = statistics.median(cpu_p)
    p_rel = p_med * 100 / statistics.median(x["cpuMean"] for x in pairs[("D", 1000)])
    t12_p99 = [x["rtt"]["p99"] for x in matrix[("T12", 1000)]]
    d_p99 = [x["rtt"]["p99"] for x in matrix[("D", 1000)]]
    ratios = [t / d for t, d in zip(t12_p99, d_p99)]
    t12_u99 = [x["update"]["p99"] for x in matrix[("T12", 1000)]]
    d_u99 = [x["update"]["p99"] for x in matrix[("D", 1000)]]
    p99_100 = [x["rtt"]["p99"] for c in DIAG_CONFIGS for x in matrix[(c, 100)]]
    lat = [runs[n] for n in lat_runs]
    keep_up = all(x["i2v"]["seen"] == x["i2v"]["sent"] and x["i2v"]["superseded"] == 0 and x["i2v"]["timedOut"] == 0
                  for x in lat)
    a_lat = row("latency-A-1000", host)["i2v"]
    i2v99 = {cfg: [x["i2v"]["latencyMs"]["p99"] for x in lat if x["cfg"] == cfg] for cfg in ("D", "L", "P")}
    lat_cpu = [x["cpuMean"] for x in lat]
    l_runs = [n for n in prof_runs if "-L-" in n]
    l_zero = all(phase_sync(runs[n]["report"], ph)["syncFolds"] == 0
                 and phase_sync(runs[n]["report"], ph)["syncDeferredTurns"] == 0 for n in l_runs for ph in PHASES)
    busy_zero = all(phase_sync(runs[n]["report"], ph)["syncSkipsBusy"] == 0 for n in prof_runs for ph in PHASES)
    backlog = {(n, ph): phase_sync(runs[n]["report"], ph)["syncSkipsBacklog"] for n in prof_runs for ph in PHASES}
    nonzero_backlog = {k: v for k, v in backlog.items() if v}
    lat_backlog = {n: backlog[(n, "steady")] for n in ("diag-profLat-D-1000", "diag-profLat-L-1000")}
    other_backlog = {k: v for k, v in nonzero_backlog.items() if not k[0].startswith("diag-profLat-")}
    p_ctx = ctx_cmp[("P − D", "1000, actions only")]
    p100_ctx = ctx_cmp[("P − D", "100, actions only")]
    plat_ctx = ctx_cmp[("P − D", "1000, MoveTo 2/s")]
    l_ctx = [ctx_cmp[("L − D", w)]["allThreads"][0] for w in ("100, profiled", "1000, profiled", "1000, profiled, MoveTo 2/s")]

    def span(vals, fmt=signp):
        return f"{fmt(min(vals))} to {fmt(max(vals))}"

    bullets = [
        "**Server CPU at 1000 rooms (D3).** " + claim(
            abs(t12_pts) < d_range and abs(l_pts) < d_range,
            f"T12 − D is {sign1(t12_pts)} points ({signp(t12_rel)}) and L − D {sign1(l_pts)} ({signp(l_rel)}), "
            f"median against median. Both are smaller than D's own range over its 3 suites, {d_range:.1f} points.")
        + f" P − D is {sign1(p_med)} points as the median of the 3 pair differences ({signp(p_rel)} of D's median), "
        f"with pair differences of {', '.join(sign1(v) for v in cpu_p)} (D5). "
        + claim(max(abs(t12_rel), abs(l_rel), abs(p_rel)) < abs(ab_rel) / 2,
                f"For scale: B − A at 1000 rooms in step 2 was {signp(ab_rel)}."),
        "**RTT tail with 12 event loops (D2, D3).** " + claim(
            min(t12_p99) > max(d_p99),
            f"T12's 1000-room RTT p99 is {f2(statistics.median(t12_p99))} ms median "
            f"[{f2(min(t12_p99))}–{f2(max(t12_p99))}] against D's {f2(statistics.median(d_p99))} "
            f"[{f2(min(d_p99))}–{f2(max(d_p99))}]: every T12 run is above every D run.")
        + f" Per suite, T12 / D is {', '.join(f'{v:.1f}×' for v in ratios)}; the ratio of the medians is "
        f"{statistics.median(t12_p99) / statistics.median(d_p99):.1f}×. "
        + claim(min(t12_u99) > max(d_u99),
                f"Update p99 is {min(t12_u99)}–{max(t12_u99)} ms for T12 and {min(d_u99)}–{max(d_u99)} ms for D.")
        + f" At 100 rooms all {len(p99_100)} matrix runs have an RTT p99 of {f2(min(p99_100))}–{f2(max(p99_100))} ms (D1).",
        "**RTT and update tails without the phase offset (D5).** " + claim(
            all(v > 0 for v in p99_p) and all(v > 0 for v in u99_p) and all(v > 0 for v in pd[1000][1]),
            f"At 1000 rooms P's RTT p50, RTT p99 and update p99 are above D's in all 3 pairs: RTT p99 by "
            f"{', '.join(f'{v:+.2f}' for v in p99_p)} ms, update p99 by {', '.join(f'{v:+d}' for v in u99_p)} ms.")
        + " " + claim(all(abs(v) < 0.1 for v in pd[100][2]),
                      f"At 100 rooms the RTT p99 differences are {', '.join(f'{v:+.2f}' for v in pd[100][2])} ms."),
        "**MoveTo at 2/s, 1000 rooms (D6).** " + claim(
            keep_up,
            f"In all {len(lat)} runs ({', '.join(x['cfg'] for x in lat)}, in run order) every input was seen: "
            f"seen = sent, 0 superseded, 0 timed out.")
        + f" Input-to-visible p99 is {min(i2v99['D'])}–{max(i2v99['D'])} ms for D, "
        f"{min(i2v99['L'])}–{max(i2v99['L'])} for L and {min(i2v99['P'])}–{max(i2v99['P'])} for P, at server CPU "
        f"{min(lat_cpu):.1f}–{max(lat_cpu):.1f} %. "
        f"For comparison, A at the same load in step 4: {a_lat['superseded']:,} of {a_lat['sent']:,} inputs superseded.",
        "**L runs the legacy sync path (D7).** " + claim(
            l_zero, f"Its {len(l_runs)} profiled runs show 0 folds and 0 deferred turns in every phase.")
        + " " + claim(busy_zero, "`syncSkipsBusy` is 0 in every phase of all 6 profiled runs.")
        + " " + claim(
            all(v > 0 for v in lat_backlog.values()) and len(other_backlog) <= 1 and all(v <= 1 for v in other_backlog.values()),
            "Backlog skips appear under MoveTo at 2/s: "
            + ", ".join(f"{lat_backlog[n]:,} ({n.split('-')[2]})" for n in lat_backlog)
            + " in the steady phase. Elsewhere: "
            + (", ".join(f"{v} in {k[0]} {k[1]}" for k, v in other_backlog.items()) or "none") + "."),
        "**Context switches (D8, D9).** " + claim(
            all(v < 0 for v in p_ctx["allThreads"] + p_ctx["wholeWindow"]),
            f"At 1000 rooms, actions only, P has fewer voluntary switches than D in all 3 pairs: "
            f"{span(p_ctx['allThreads'])} counting all threads seen, {span(p_ctx['wholeWindow'])} counting the "
            f"threads present for the whole window.")
        + f" At 100 rooms: {span(p100_ctx['allThreads'])} (n = 3). Under MoveTo at 2/s: "
        f"{', '.join(signp(v) for v in plat_ctx['allThreads'])} (n = 2). L − D, profiled, one pair per row: "
        f"{', '.join(signp(v) for v in l_ctx)} at 100, 1000 and 1000 with MoveTo. "
        f"T12 − D at 1000 (n = 1): {signp(ctx_cmp[('T12 − D', '1000, actions only')]['allThreads'][0])}.",
    ]
    parts.append("### Findings\n\n" + "\n".join(f"- {b}" for b in bullets))
    return "\n\n".join(parts) + "\n"


def replace_between(text, start, end, body):
    head, rest = text.split(start, 1)
    _, tail = rest.split(end, 1)
    return f"{head}{start}\n\n{body}\n{end}{tail}"


def main():
    text = README.read_text()
    new = replace_between(text, START, END, build())
    new = replace_between(new, DIAG_START, DIAG_END, build_diagnosis())
    if "--check" in sys.argv:
        if new != text:
            print("README.md generated sections are stale: run python3 regenerate.py", file=sys.stderr)
            sys.exit(1)
        print("README.md generated sections are current.")
        return
    README.write_text(new)


if __name__ == "__main__":
    main()
