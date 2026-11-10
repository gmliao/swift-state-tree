#!/usr/bin/env python3
"""Rebuild this topic's Results section: the refreeze sweep (results/, run.sh and collect.py), then
the 2026-11-06 set under data/ as the pre-refreeze record, with its comparisons.

  python3 regenerate.py          rewrite the Results section of README.md
  python3 regenerate.py --check  exit 1 if README.md's Results section is stale
  python3 regenerate.py --results <dir> --markdown
                                 print the Results section built from <dir> instead of results/
                                 (a dry run on a fixture or scratch sweep); README.md isn't touched

The MoveTo arms (#430) are the sweeps under results/ (results/<RUN_ID>/sweep.json): one per arm
(run.sh MOVE_TO_PER_S 0, 2, 5) and at most one host-drift control (CONTROL=1), all at one commit.
Each arm's tables come after every gate of --sweep below, then a sensitivity table across the arms
and the control's line (reported, not tabled). A second sweep for an arm, a second control, mixed
commits, or a sweep that records no arm is refused (collect only the ones, `collect.py --run-id`).
With none, the section says the sweeps haven't run. An earlier set goes under results/archive/,
which the section doesn't read: --sweep results/archive/<RUN_ID> still prints its tables.
The pre-refreeze record must resolve to both knobs off (wireform, by its commit's ancestry: its
reports predate the joins' recording); it renders under a caption that names that form and is
never compared with the sweep.
  python3 regenerate.py --sweep results/<RUN_ID>
                                 print the tables of one run.sh sweep (collect.py's output), or
                                 refuse it: a debug build, a dirty tree, a smoke sweep (only some
                                 runs, overrides, other phases), a missing or stopped run, an
                                 unpinned run, a Swift version other than the pinned one or than
                                 the sweep's, a GameServer from another commit, a profile flag
                                 off the matrix, a send-backlog setting (the question is the
                                 shipped defaults), or joins whose state-update features differ
                                 from the declared wire form (PATH_INDEX, FIELD_MERGE)

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

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import gameserver_wire  # noqa: E402
import landstats  # noqa: E402
import provenance  # noqa: E402
import wireform  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
import clientload  # noqa: E402
import profiler_overhead  # noqa: E402

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
    updates = m.get("stateUpdates") or {}
    moves = (m.get("events") or {}).get("MoveTo") or {}
    per_recipient = (updates["bytesMean"] * updates["perPlayerPerSecond"]
                     if isinstance(updates.get("bytesMean"), (int, float)) and isinstance(updates.get("perPlayerPerSecond"), (int, float))
                     else None)
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
        "rooms": layout.get("lands"),  # one land per room
        # The arms (#430): MoveTo events each player sent per second, and the update bytes each
        # recipient received per second (mean update size × updates per player per second).
        "movesPerPlayer": moves.get("perPlayerPerSecond", 0 if m else None),
        "bytesPerRecipientS": per_recipient,
        # The measured 1 s windows' RTT, (s from the origin, p50, p99), and the host's 1-minute load
        # average, (s from the origin, load1): what the profiler-overhead pair's flag names.
        "rttWindows": [(w["startMs"] // 1000, w["rtt"]["p50"], w["rtt"]["p99"])
                       for w in m.get("windows") or [] if not w.get("warmup") and (w.get("rtt") or {}).get("count")],
        "load1": [((e["tsMs"] - m["originAt"]) / 1000, e["load1"]) for e in report.get("system") or []
                  if isinstance(m.get("originAt"), (int, float)) and isinstance(e.get("tsMs"), (int, float))
                  and isinstance(e.get("load1"), (int, float))],
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


def run_tables(runs, suite_run, rooms=None, top=500):
    """The per-run, server-counter, per-room-count and profiler-overhead tables. `suite_run(s, r)`
    names suite s's run at r rooms in `runs`; `rooms` are the suites' room counts (ROOMS unless the
    sweep ran others) and `top` the overhead pair's."""
    rooms = rooms or ROOMS
    parts = []
    # Per run.
    rows = []
    for s in SUITES:
        for r in rooms:
            x = runs[suite_run(s, r)]
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
        for r in rooms:
            x = runs[suite_run(s, r)]
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
    for r in rooms:
        xs = [runs[suite_run(s, r)] for s in SUITES]
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
    parts.append(f"### Profiler overhead, {top} rooms, back to back\n\n" + table(
        ["steady phase", "profiled", "unprofiled", "difference", "relative"], rows)
        + f"\n\nBoth runs: {on['disconnects']} and {off['disconnects']} disconnects."
        + overhead_flag(on, off))
    return parts


def overhead_flag(on, off):
    """For a set whose pair breaks the profiler-overhead bound (profiler_overhead.py, applied since
    the arms, which refuse it): a flag under the pair's table, with the profiled run's windows over
    the bound and the host's load average around them, as observed. "" within the bound."""
    a, b = on["rtt"]["p99"], off["rtt"]["p99"]
    if profiler_overhead.failure_of(a, b) is None:
        return ""
    limit = b + profiler_overhead.allowed_excess(b)
    over = [w for w in on["rttWindows"] if w[2] > limit]
    text = (f"\n\n**Outside the profiler-overhead bound** applied since the MoveTo arms: profiled steady RTT p99 {a:.2f} ms "
            f"against {b:.2f} ms, over max(+{profiler_overhead.MIN_EXCESS_MS:g} ms, +{profiler_overhead.MAX_EXCESS_SHARE:.0%}). "
            "This set predates the gate: archived, not refused.")
    if over:
        windows = "; ".join(f"{s} s: p50 {p50:.2f}, p99 {p99:.2f} ms" for s, p50, p99 in over)
        text += (f" Observed: in the profiled run, {len(over)} of its {len(on['rttWindows'])} measured 1 s windows had an RTT p99 "
                 f"over {limit:.2f} ms ({windows}, counted from the steady origin).")
        first, last = over[0][0], over[-1][0]
        before = [l for t, l in on["load1"] if t < first]
        during = [l for t, l in on["load1"] if first <= t < last + 1]
        if before and during:
            text += f" The host's 1-minute load average was {before[-1]:g} before them and {max(during):g} during them."
    return text


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

    parts = run_tables(runs, lambda s, r: f"rerun-suite-{s}-{r}")
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


# run.sh's matrix: name -> (rooms, profiled). test_topic.py checks it against run.sh's dry run.
def matrix_for(top=500, rooms=ROOMS):
    """run.sh's matrix at a top room count (the preflight and the overhead pair; TOP_ROOMS) and the
    suites' room counts (SUITE_ROOMS)."""
    matrix = {"preflight": (top, True), "overhead-profiled": (top, True), "overhead-unprofiled": (top, False)}
    matrix.update({f"suite-{s}-{r}": (r, True) for s in SUITES for r in rooms})
    return matrix


MATRIX = matrix_for()


def rooms_of(sweep):
    """(top room count, the suites' room counts) a sweep ran: run.json's topRooms and suiteRooms,
    or the defaults for a sweep from before they were recorded."""
    return sweep.get("topRooms") or 500, tuple(sweep.get("suiteRooms") or ROOMS)
# The default scenario's phases (scenarios/hero-defense/default.json), as the reports record them.
PHASES = {"preflight": (2, 10, 1), "steady": (5, 60, 1), "postflight": (2, 10, 1)}  # players, seconds, actions/s
# The hold run.sh gives steady since the spawn ramp is skipped (#425; STEADY_WARMUP_S): steady runs
# this much longer at 5 players per room, as its warm-up, before its 60 s measured window. A sweep
# that records it (steadyWarmupS) must have it in every report, have run without the spawn ramp,
# and have a stationary monster load in every run's measured window (landstats.py). Sweeps without
# it (the 2026-11-06 set, the refreeze) ran the game's own ramp and no hold.
STEADY_HOLD_S = 30
# The game's load a sweep ran (run.sh WORKLOAD): (the spawn ramp the servers must report, the hold).
# plateau: no ramp, steady held STEADY_HOLD_S, the steady window stationary (landstats.py). refreeze:
# the refreeze sweep's rules, the game's own ramp (3000 ticks) and ws-loadtest's default warm-up, so
# the load rises through steady and no stationarity applies. An arm set runs one workload.
WORKLOADS = {"plateau": (0, STEADY_HOLD_S), "refreeze": (3000, None)}
WORKLOAD_CAPTIONS = {
    "plateau": "Workload: Hero Defense's spawn ramp skipped and steady held 30 s before its 60 s measured window, so the "
               "monster load is at its plateau there (every window stationary, `landstats.py`).",
    "refreeze": "Workload: the refreeze sweep's rules, Hero Defense's own spawn ramp (3000 ticks, 150 s) and ws-loadtest's "
                "default warm-up (the connect ramp plus 2 s), so each land's monster load rises through steady "
                "(see the limit under the README's MoveTo arms).",
}


def workload_of(sweep):
    """The workload a sweep ran: run.json's workload, or plateau for a sweep that records the hold
    without naming it (the arms before WORKLOAD), or None (a sweep from before the arms)."""
    return sweep.get("workload") or ("plateau" if sweep.get("steadyWarmupS") is not None else None)
# The MoveTo arms (#430; run.sh MOVE_TO_PER_S): one sweep per arm, at one commit. A sweep that
# records moveToPerS is an arm sweep: its reports must send that many MoveTo events per player per
# second (none at 0) and its load client must not have been the bottleneck (clientload.py).
ARMS = (0, 2, 5)
# The host-drift control (run.sh CONTROL=1): suite-1's run at 300 rooms, at arm 0, after the arms.
CONTROL_MATRIX = {"control-300": (300, True)}
CONTROL_ROOMS = 300
PINNED_SWIFT = "Swift version 6.2.4 (swift-6.2.4-RELEASE)"
SERVER_CPUS, CLIENT_CPUS = "0-7", "8-11"
# A run's status: run.sh records "passed" or "failed-run" for a run that ran to the end (a failed
# run is a result, shown as FAIL); any other status means the sweep stopped at that run.
FINISHED = ("passed", "failed-run")


def cpus(text):
    out = set()
    for part in filter(None, (text or "").strip().split(",")):
        a, _, b = part.partition("-")
        out.update(range(int(a), int(b or a) + 1))
    return out


def intended_form(wire):
    """The form the sweep's server sends for its declared environment (run.json `wire`), by the
    server's rules (gameserver_wire: JSON-object updates have no features; otherwise each is on
    unless "false"). Each run's form is what its joins' responses named, checked against this."""
    return gameserver_wire.intended(wire)


def matrix_of(sweep):
    """The runs a sweep must have: the control's one, or run.sh's matrix at the room counts it ran."""
    return CONTROL_MATRIX if sweep.get("control") else matrix_for(*rooms_of(sweep))


def move_to_rate(report):
    """The MoveTo events per player per second a report's client was configured to send (0 for none)."""
    events = ((report.get("meta") or {}).get("runConfig") or {}).get("events") or []
    rates = [e.get("ratePerSecond") for e in events if e.get("name") == "MoveTo"]
    return rates[0] if len(rates) == 1 else (0 if not rates else rates)


# An arm's client must send what it was configured to: in every phase's measured window, MoveTo
# achieved at least this share of its target (the rate × the average joined connections).
MOVE_TO_ACHIEVED_MIN = 0.95


def move_to_failures(report, arm):
    """Why a report's MoveTo sending doesn't match its arm: the configured rate, and per phase the
    achieved rate (measurement.events.MoveTo); arm 0 sends none. [] when it matches."""
    out = []
    configured = move_to_rate(report)
    if configured != arm:
        out.append(f"the client was configured for MoveTo at {configured!r} per player per second, the arm is {arm!r}")
    for phase in report.get("phases") or []:
        moves = ((phase.get("measurement") or {}).get("events") or {}).get("MoveTo")
        if arm == 0:
            if moves and moves.get("sentInWindow"):
                out.append(f"{phase.get('name')}: {moves['sentInWindow']} MoveTo sent at arm 0")
        elif not moves:
            out.append(f"{phase.get('name')}: no MoveTo sending recorded (measurement.events.MoveTo)")
        else:
            target, achieved = moves.get("targetPerSecond"), moves.get("achievedPerSecond")
            if not isinstance(target, (int, float)) or not isinstance(achieved, (int, float)) or target <= 0:
                out.append(f"{phase.get('name')}: MoveTo target {target!r}, achieved {achieved!r}: not measurable")
            elif achieved < MOVE_TO_ACHIEVED_MIN * target:
                out.append(f"{phase.get('name')}: MoveTo achieved {achieved:.1f}/s of a {target:.1f}/s target "
                           f"({achieved / target:.0%}), under {MOVE_TO_ACHIEVED_MIN:.0%}")
    return out


def sweep_failures(sweep, reports):
    """Why a collected sweep (results/<RUN_ID>/sweep.json and its reports) can't be tabled; [] if it can."""
    failures = []
    matrix = matrix_of(sweep)
    top, suite_rooms = rooms_of(sweep)
    if list(suite_rooms) != sorted(set(suite_rooms)) or not suite_rooms or max(suite_rooms) > top:
        failures.append(f"suite room counts {list(suite_rooms)} with top {top}: they must ascend, without repeats, none over the top")
    arm = sweep.get("moveToPerS")
    # collect.py writes moveToPerS: null for a sweep from before the arms: the value, not the key, says.
    is_arm = arm is not None
    if is_arm:
        if arm not in ARMS:
            failures.append(f"MoveTo arm {arm!r}: the arms are {', '.join(map(str, ARMS))}")
        if sweep.get("control") and arm != 0:
            failures.append(f"a control at arm {arm!r}: the control runs arm 0")
    elif sweep.get("control"):
        failures.append("a control sweep without its arm recorded (moveToPerS)")
    git = sweep.get("git") or {}
    if not git.get("commit"):
        failures.append("no commit recorded")
    if git.get("dirty") is None:
        failures.append("not from a clean tree (git dirty: None): no git.dirty recorded; run the sweep with this topic's run.sh, whose runmeta.py records git.dirty in run.json")
    elif git.get("dirty") is not False:
        failures.append(f"not from a clean tree (git dirty: {git.get('dirty')})")
    if sweep.get("buildConfig") != "release":
        failures.append(f"not a release build (buildConfig {sweep.get('buildConfig')!r})")
    if sweep.get("swiftVersion") != PINNED_SWIFT:
        failures.append(f"Swift {sweep.get('swiftVersion')!r}, the pinned toolchain is {PINNED_SWIFT!r}")
    if sweep.get("onlyRuns"):
        failures.append(f"a smoke sweep: only runs {sweep['onlyRuns']}")
    if sweep.get("overrides"):
        failures.append(f"a smoke sweep: overrides {sweep['overrides']}")
    if sweep.get("pinCpus") != f"server:{SERVER_CPUS} client:{CLIENT_CPUS}":
        failures.append(f"pinning {sweep.get('pinCpus')!r}, the matrix pins server:{SERVER_CPUS} client:{CLIENT_CPUS}")
    if not sweep.get("endedAt"):
        failures.append("the sweep didn't finish (no end time)")
    backlog = sweep.get("sendBacklogEnv")
    if backlog is None:
        failures.append("the send-backlog settings weren't recorded")
    elif any(backlog.values()):
        failures.append(f"send-backlog settings {backlog}: the question is the shipped defaults")
    hold = sweep.get("steadyWarmupS")
    workload = workload_of(sweep)
    expected_ramp = None
    if sweep.get("workload") is not None and sweep["workload"] not in WORKLOADS:
        failures.append(f"workload {sweep['workload']!r}: the workloads are {', '.join(WORKLOADS)}")
    elif workload is not None:
        expected_ramp, expected_hold = WORKLOADS[workload]
        if hold != expected_hold:
            failures.append(f"steady warm-up {hold!r} s, the {workload} workload holds {expected_hold!r}")
        if sweep.get("spawnRampTicks") != expected_ramp:
            failures.append(f"spawn ramp {sweep.get('spawnRampTicks')!r} asked for: the {workload} workload runs {expected_ramp}")
    elif is_arm:
        failures.append("an arm sweep that records no workload (WORKLOAD) or hold")
    phases = dict(PHASES, steady=(PHASES["steady"][0], PHASES["steady"][1] + (hold or 0), PHASES["steady"][2]))
    wire = sweep.get("wire")
    intended = intended_form(wire) if wire is not None else None
    forms = {}
    if wire is None:
        failures.append("the wire form (PATH_INDEX, FIELD_MERGE) wasn't recorded")
    runs = sweep.get("runs") or {}
    missing = [n for n in matrix if n not in runs or not runs[n].get("report")]
    if missing:
        failures.append(f"missing runs: {', '.join(missing)}")
    extra = sorted(set(runs) - set(matrix))
    if extra:
        failures.append(f"runs not in the matrix: {', '.join(extra)}")
    node_versions = set()
    for name, (rooms, profiled) in matrix.items():
        run = runs.get(name)
        if not run or not run.get("report"):
            continue
        if run.get("status") not in FINISHED:
            failures.append(f"{name}: status {run.get('status')!r}")
        tc = run.get("toolchain") or {}
        if tc.get("swift") != sweep.get("swiftVersion"):
            failures.append(f"{name}: Swift {tc.get('swift')!r}, the sweep recorded {sweep.get('swiftVersion')!r}")
        binary = tc.get("gameserverBin") or ""
        if "/release/" not in binary:
            failures.append(f"{name}: GameServer {binary or '<not recorded>'!r} isn't a release build")
        if tc.get("sourceSha") != git.get("commit"):
            failures.append(f"{name}: GameServer from {tc.get('sourceSha')!r}, the sweep is at {git.get('commit')!r}")
        if run.get("profiled") != profiled:
            failures.append(f"{name}: profiled {run.get('profiled')}, the matrix has {profiled}")
        shims = run.get("shims") or {}
        if f"taskset -c {SERVER_CPUS} " not in shims.get("stdbuf", "") or f"taskset -c {CLIENT_CPUS} " not in shims.get("node", ""):
            failures.append(f"{name}: unpinned (shims {shims})")
        if not run.get("serverAffinity") or cpus(run["serverAffinity"]) != cpus(SERVER_CPUS):
            failures.append(f"{name}: the server ran on CPUs {run.get('serverAffinity')!r}, not {SERVER_CPUS}")
        run_backlog = run.get("sendBacklogEnv")
        if run_backlog is None or any(run_backlog.values()):
            failures.append(f"{name}: send-backlog settings {run_backlog}, not the shipped defaults")
        try:
            # The joins' one form (wireform.join_form); None: not recorded, resolved by ancestry.
            joined = wireform.join_form(run.get("stateUpdateFeatures"))
            encoding, features = joined if joined is not None else (None, None)
            forms[name] = wireform.resolve(git.get("commit"), encoding, features=features)
        except wireform.MissingWireForm as e:
            failures.append(f"{name}: wire form missing: {e}")
        meta = ((reports.get(name) or {}).get("meta") or {}).get("runConfig") or {}
        node_versions.add(meta.get("nodeVersion"))
        got = {p.get("name"): (p.get("rooms"), p.get("playersPerRoom"), p.get("durationSeconds"), p.get("actionsPerSecond"))
               for p in meta.get("phases") or []}
        want = {phase: (rooms, *spec) for phase, spec in phases.items()}
        if got != want:
            failures.append(f"{name}: phases {got}, the matrix has {want}")
        if expected_ramp is not None:
            effective = (sweep.get("spawnRampTicksEffective") or {}).get(name)
            if effective != expected_ramp:
                failures.append(f"{name}: the server reported spawn ramp {effective!r}, not {expected_ramp}")
        if hold is not None:
            steady = next((p for p in meta.get("phases") or [] if p.get("name") == "steady"), {})
            if steady.get("warmupMs") != hold * 1000:
                failures.append(f"{name}: steady warm-up {steady.get('warmupMs')!r} ms, the sweep holds {hold * 1000} ms")
            stats = run.get("steadyLandStats")
            if stats is None:
                failures.append(f"{name}: no land stats for the steady window (land-stats.jsonl)")
            elif not landstats.stationary(stats):
                failures.append(f"{name}: the steady window's monster load isn't stationary (CoV {stats['cov']}, largest "
                                f"deviation {stats['maxDev']:.0%}, drift {stats['drift']:+.0%}; bounds "
                                f"{landstats.COV_BOUND}, {landstats.MAX_DEV:.0%}, {landstats.DRIFT_BOUND:.0%})")
        if is_arm:
            failures.extend(f"{name}: {why}" for why in move_to_failures(reports.get(name) or {}, arm))
            failures.extend(f"{name}: {why}" for why in clientload.failures(run.get("clientLoad")))
    # Every table's RTT is from profiled runs: an arm's profiler-overhead pair must show the
    # profiler didn't move the tail (profiler_overhead.py; run.sh stops the sweep on it).
    if is_arm and not sweep.get("control") and "overhead-profiled" in reports and "overhead-unprofiled" in reports:
        why = profiler_overhead.failure(reports["overhead-profiled"], reports["overhead-unprofiled"])
        if why:
            failures.append(why)
    if intended is not None:
        failures.extend(wireform.check(forms, intended))
    if node_versions and node_versions != {sweep.get("nodeVersion")}:
        failures.append(f"Node {sorted(map(str, node_versions))} in the reports, the sweep recorded {sweep.get('nodeVersion')!r}")
    return failures


def sweep_provenance(sweep):
    """The sweep's provenance line (provenance.py), from sweep.json: one sweep, one record."""
    git = sweep.get("git") or {}
    return provenance.line([provenance.Meta("sweep.json", git.get("commit"), git.get("dirty"), sweep.get("swiftVersion"),
                                            sweep.get("nodeVersion"), sweep.get("buildConfig"))])


def checked_sweep(directory):
    """A collected sweep that passes every gate: (sweep.json, its provenance line, its steady rows);
    exits naming every failure otherwise."""
    sweep = json.loads((directory / "sweep.json").read_text())
    reports = {n: load_gz(directory / n / "report.json.gz") for n, r in (sweep.get("runs") or {}).items()
               if r.get("report") and (directory / n / "report.json.gz").exists()}
    failures = sweep_failures(sweep, reports)
    head = None
    try:
        head = sweep_provenance(sweep)
    except provenance.Refused as e:
        failures.append(str(e))
    if failures:
        sys.exit(f"{directory.name}: results not usable:\n  " + "\n  ".join(failures))
    return sweep, head, {n: steady_row(reports[n]) for n in matrix_of(sweep)}


def build_sweep(directory):
    sweep, head, runs = checked_sweep(directory)
    if sweep.get("control"):
        x = runs["control-300"]
        return (f"{head}\n\nControl sweep `{sweep['runId']}` (suite-1 at {CONTROL_ROOMS} rooms, arm 0): server CPU mean "
                f"{f1(x['cpuMean'])} %, {f2(per_room(x))} % per room; RTT p99 {f2(x['rtt']['p99'])} ms; "
                f"{x['disconnects']} disconnects.\n")
    form = intended_form(sweep["wire"])
    note = (f"{head}\n\nSweep `{sweep['runId']}`, "
            f"wire form {form.caption()}. Host CPU isn't sampled by run.sh (n/a)."
            + ("" if not (form.path_index or form.field_merge) else
               " The 2026-11-06 set ran without path indices and merged entries, so its bytes and CPU aren't "
               "comparable with this sweep's like for like."))
    top, suite_rooms = rooms_of(sweep)
    if (top, suite_rooms) != (500, ROOMS):
        note += f" Room counts: the preflight and the overhead pair at {top}, the suites at {', '.join(map(str, suite_rooms))}."
    return note + "\n\n" + "\n\n".join(run_tables(runs, lambda s, r: f"suite-{s}-{r}", suite_rooms, top)) + "\n"


RESULTS = HERE / "results"
RECORD_COMMIT = HERE / "data" / "provenance" / "SHA.txt"


def demote(markdown, levels=1):
    """Headings `levels` levels down, so a section's tables sit under its caption."""
    return "\n".join("#" * levels + line if line.startswith("### ") else line for line in markdown.split("\n"))


def per_room(x):
    """Server CPU per room (%, 100 = one core), from a steady row."""
    return x["cpuMean"] / x["rooms"] if x["cpuMean"] is not None and x["rooms"] else None


def sensitivity_table(arms):
    """Per room count, each metric's median [min–max] over the 3 suites, one column per arm (#430);
    the room counts any arm ran, "not run" where an arm left one out (SUITE_ROOMS)."""
    rows = []
    for r in sorted({int(name.rsplit("-", 1)[1]) for runs in arms.values() for name in runs if name.startswith("suite-")}):
        for label, pick, fmt in (
            ("MoveTo sent per player per s", lambda x: x["movesPerPlayer"], f2),
            ("server CPU mean (%)", lambda x: x["cpuMean"], f1),
            ("server CPU per room (%)", per_room, f2),
            ("update bytes per recipient per s", lambda x: x["bytesPerRecipientS"], f1),
            ("RTT p99 (ms)", lambda x: x["rtt"]["p99"], f2),
            ("disconnects (sum)", lambda x: x["disconnects"], fi),
        ):
            cells = []
            for arm in ARMS:
                if arm not in arms or f"suite-1-{r}" not in arms[arm]:
                    cells.append("not run")
                    continue
                xs = [arms[arm][f"suite-{s}-{r}"] for s in SUITES]
                cells.append(fi(sum(x["disconnects"] for x in xs)) if label.startswith("disconnects") else rng([pick(x) for x in xs], fmt))
            rows.append([r, label, *cells])
    return ("### Sensitivity to the players' input rate: median [min–max] over the 3 suites\n\n"
            "Each arm adds that many MoveTo events per player per second to the 1 PlayAction/s. Capacity is the room "
            "count with zero disconnects. The input-turn cost #430 asks for isn't in the client's report (the "
            "server's turn timings are in the profiler output only), so it isn't tabled.\n\n"
            + table(["rooms", "steady phase", *(f"MoveTo {a}/s" for a in ARMS)], rows))


def control_line(control, arm0):
    """The host-drift control against arm 0's runs at the same room count: reported, not tabled."""
    sweep, head, runs = control
    x = runs["control-300"]
    if f"suite-1-{CONTROL_ROOMS}" not in arm0:
        return (f"**Host-drift control** (`{sweep['runId']}`): not compared, since arm 0 ran no {CONTROL_ROOMS}-room suites "
                "(SUITE_ROOMS). It isn't tabled.")
    band = [per_room(arm0[f"suite-{s}-{CONTROL_ROOMS}"]) for s in SUITES]
    value = per_room(x)
    within = value is not None and None not in band and min(band) <= value <= max(band)
    verdict = ("within it" if within else
               "**outside it: the set is flagged for host drift** (compare the arms' numbers with care)")
    return (f"**Host-drift control** (`{sweep['runId']}`, suite-1 at {CONTROL_ROOMS} rooms at arm 0, run after the "
            f"arms): server CPU {f2(value)} % per room, against arm 0's {CONTROL_ROOMS}-room runs "
            f"[{f2(min(b for b in band if b is not None)) if any(b is not None for b in band) else 'n/a'}–"
            f"{f2(max(b for b in band if b is not None)) if any(b is not None for b in band) else 'n/a'}]: {verdict}. "
            "It isn't tabled.")


def sweep_dirs(results):
    return sorted(p.parent for p in pathlib_glob(results, "*/sweep.json"))


def pathlib_glob(directory, pattern):
    return list(directory.glob(pattern)) if directory.is_dir() else []


ARMS_CAPTION = "### MoveTo arms (#430)"


def sweep_section(results):
    """The arm sweeps' tables, gated (checked_sweep), with their sensitivity table and the drift
    control's line; a placeholder before they run. results/ holds one sweep per arm and at most
    one control, all at one commit; an archived set (results/archive/) is no input."""
    dirs = sweep_dirs(results)
    if not dirs:
        return (f"{ARMS_CAPTION}\n\n_Not run yet: the measurement host's run.sh sweeps (MOVE_TO_PER_S 0, 2 and 5, "
                "then CONTROL=1), collected into results/, fill this section._\n")
    records = {d: json.loads((d / "sweep.json").read_text()) for d in dirs}
    legacy = [d.name for d, r in records.items() if r.get("moveToPerS") is None and not r.get("control")]
    if legacy:
        sys.exit(f"results not usable: {', '.join(legacy)} records no MoveTo arm (moveToPerS): a sweep from before "
                 "the arms goes under results/archive/")
    controls = [d for d, r in records.items() if r.get("control")]
    by_arm = {}
    for d, r in records.items():
        if not r.get("control"):
            by_arm.setdefault(r.get("moveToPerS"), []).append(d)
    twice = {arm: ds for arm, ds in by_arm.items() if len(ds) > 1}
    if twice:
        sys.exit("results not usable: more than one sweep for an arm: "
                 + "; ".join(f"{arm}: {', '.join(d.name for d in ds)}" for arm, ds in sorted(twice.items(), key=str)))
    if len(controls) > 1:
        sys.exit(f"results not usable: {len(controls)} control sweeps ({', '.join(d.name for d in controls)}); keep one")
    commits = {(r.get("git") or {}).get("commit") for r in records.values()}
    if len(commits) > 1:
        sys.exit(f"results not usable: the sweeps are from {len(commits)} commits ({', '.join(sorted(map(str, commits)))}); "
                 "the arms and the control run at one")
    if controls and 0 not in by_arm:
        sys.exit("results not usable: a control sweep without the arm-0 sweep it's checked against")
    workloads = {workload_of(r) for r in records.values()}
    if len(workloads) > 1:
        sys.exit("results not usable: the sweeps ran different workloads ("
                 + "; ".join(f"{d.name}: {workload_of(r)}" for d, r in sorted(records.items())) + "); the arms and the control run one")
    parts, arms = [ARMS_CAPTION], {}
    workload = next(iter(workloads))
    if workload in WORKLOAD_CAPTIONS:
        parts.append(WORKLOAD_CAPTIONS[workload])
    for arm in ARMS:
        if arm not in by_arm:
            parts.append(f"#### MoveTo {arm}/s per player\n\n_Not run yet._")
            continue
        directory = by_arm[arm][0]
        _, _, arms[arm] = checked_sweep(directory)
        parts.append(f"#### MoveTo {arm}/s per player\n\n" + demote(build_sweep(directory), 2).rstrip("\n"))
    unknown = sorted(set(by_arm) - set(ARMS), key=str)
    for arm in unknown:
        checked_sweep(by_arm[arm][0])  # refused by its gate, by name
    if len(arms) > 1:
        parts.append(demote(sensitivity_table(arms)))
    if controls:
        parts.append(control_line(checked_sweep(controls[0]), arms[0]))
    return "\n\n".join(parts) + "\n"


def check_record():
    """The 2026-11-06 set must resolve to both knobs off: its server commit predates them."""
    commit = RECORD_COMMIT.read_text().strip()
    try:
        form = wireform.resolve(commit, "messagepack")
    except wireform.MissingWireForm as missing:
        sys.exit(f"pre-refreeze record not usable: wire form missing: {missing}")
    if (form.path_index, form.field_merge) != (False, False):
        sys.exit(f"pre-refreeze record not usable: commit {commit} ran {form.caption()}, the record is both knobs off")
    return commit, form


def record_section():
    commit, form = check_record()
    return (f"### Pre-refreeze record (2026-11-06, server `{commit[:8]}`: {form.caption()})\n\n"
            "The set this topic published before the refreeze: the path index and field merge didn't exist at its "
            "commit, so its bytes and CPU aren't like for like with the sweep above, and it isn't compared with it. "
            "Its own comparisons (2026-11-05, 2026-02-06) are kept as published.\n\n" + demote(build()))


def results_markdown(results):
    return sweep_section(results) + "\n" + record_section()


def main():
    if "--results" in sys.argv:
        # A dry run: the whole Results section from another results directory, on stdout.
        args = sys.argv[sys.argv.index("--results") + 1:]
        if not args or args[0].startswith("--"):
            sys.exit("--results needs a directory")
        print(results_markdown(Path(args[0])), end="")
        return
    if "--sweep" in sys.argv:
        # python3 regenerate.py --sweep results/<RUN_ID>: the tables of one run.sh sweep, on stdout.
        args = sys.argv[sys.argv.index("--sweep") + 1:]
        if not args:
            sys.exit("--sweep needs a directory: results/<RUN_ID>")
        print(build_sweep(Path(args[0])), end="")
        return
    text = README.read_text()
    head, rest = text.split(START, 1)
    _, tail = rest.split(END, 1)
    new = f"{head}{START}\n\n{results_markdown(RESULTS)}\n{END}{tail}"
    if "--check" in sys.argv:
        if new != text:
            print("README.md Results are stale: run python3 regenerate.py", file=sys.stderr)
            sys.exit(1)
        print("README.md Results are current.")
        return
    README.write_text(new)


if __name__ == "__main__":
    main()
