#!/usr/bin/env python3
"""Runs one run of the matrix (plan.py) end to end and writes data/<run-id>/ (stdlib only).

  cell.py <cell> <repeat> --sweep <id> --server <GameServer> [--rooms 300] [--sr-pause S]
          [--calibration <file>] [--server-cpus 0-7] [--client-cpus 8-11] [--dry-run]

The README's per-run steps, in order. Each prints `step <name>` and a failure names its step:

1. timewait  wait until TIME_WAIT on port 8080, summed over the container namespace and every
             lt-* namespace, is at most 200 (design § 8), for at most 300 s;
2. sockets   remove the stale control sockets in /tmp;
3. setup     `impair.sh setup` with the cell's limits (`--with-good` for M and SR);
4. server    GameServer in the container namespace with the README's server line, pinned to the
             server CPUs; its transport profile and lifecycle log in the run directory;
5. samplers  sockstat (every namespace) and netem's backlog, pinned to the client CPUs;
6. schedule  `impair.sh schedule <profile>` at warm-up + baseline after the shared start, for the
             impaired segment (RATE and COMBO with --rate);
7. clients   one load client per instance (`ip netns exec <ns>`), pinned to the client CPUs, all
             from the same --start-at, with --room-slots and the worker split in M and SR, and
             --slow-read in SR;
8. converge  `converge-main.js` at the end of the recovery segment, from the server namespace;
9. finish    wait for the clients and the schedule, stop the samplers and the server;
10. teardown `impair.sh teardown` (also when a step fails, and on SIGTERM, SIGINT or SIGHUP: the
               run is recorded as stopped, every process group it started is stopped, and the
               exit status is 128 + the signal);
11. record   run.json: meta (the sweep's, the impair.sh hash, the joins' wire form per instance),
             params (rooms, population, limits, rate, jitterReorders/reorderedPct on the jitter
             cells, convergenceRoster, the slow reader's pause) and groups (loopDelayP99Ms from
             each instance's report).

Tests only (test_topic.py): IMPAIR_SH, LOADTEST_SCRIPT, NODE_TOOLS (the directory holding
converge-main.js and sockstat-main.js), HEALTH_URL, START_MARGIN_S and SCENARIO_OVERRIDE replace
the real tools and timings; run.json records SCENARIO_OVERRIDE and START_MARGIN_S when set.
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import pathlib
import re
import shlex
import signal
import subprocess
import sys
import time
import urllib.request

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC))
import calibration  # noqa: E402
import clientload  # noqa: E402
import plan  # noqa: E402
import runmeta  # noqa: E402

GAMEDEMO = TOPIC.parent.parent / "Examples" / "GameDemo"
LOADTEST = GAMEDEMO / "ws-loadtest"
IMPAIR = os.environ.get("IMPAIR_SH") or str(LOADTEST / "scripts" / "impair.sh")
LOADTEST_SCRIPT = os.environ.get("LOADTEST_SCRIPT") or "scripts/run-ws-loadtest.sh"
NODE_TOOLS = os.environ.get("NODE_TOOLS") or "dist"
HEALTH_URL = os.environ.get("HEALTH_URL") or "http://127.0.0.1:8080/schema"
ADMIN_URL = "http://10.200.0.1:8080"
API_KEY = "hero-defense-admin-key"
START_MARGIN_S = int(os.environ.get("START_MARGIN_S") or 40)
TIMEWAIT_MAX = 200
TIMEWAIT_TIMEOUT_S = 300
CONVERGE_DEADLINE_S = 35
STALE_AFTER_S = 10
RECONNECT_AFTER_LIFT_S = 60
NAMESPACES = ("lt-client", "lt-good", "lt-router")
SEND_BACKLOG_ENV = ("WS_SEND_BACKLOG_MAX_BYTES", "WS_SEND_BACKLOG_MAX_UNWRITABLE_MS")
# Sync-lag tracking's thresholds (#332): the server's environment variables, and their defaults
# (SyncLagPolicy.default), which the sweep runs and records in params.
SYNC_LAG_ENV = ("SYNC_LAG_RESYNC_MS", "SYNC_LAG_SLOW_CONSUMER_COUNT", "SYNC_LAG_SLOW_CONSUMER_WINDOW_MS",
                "SYNC_ACK_TIMEOUT_MS", "SYNC_ACK_FRESHNESS_MS", "SYNC_LAG_CLOSE_GRACE_MS")
# The sync-path switches (#468; deep-research/serverenv.py lists them for the EncodingBenchmark
# topics): the server runs the shipped sync path, so they're removed from the environment it
# inherits, and meta.syncPathEnv records what the shell had.
SYNC_PATH_ENV = ("USE_SNAPSHOT_FOR_SYNC", "IN_TURN_SYNC", "USE_SYNC_TABLES", "ROW_ADDRESSING", "SYNC_STRATEGY", "OUTBOUND_WRITER_MAX_BYTES", "JOIN_FLIP_BUDGET")


def server_environ(environ, server_env):
    """The server's environment: the shell's without the sync-path switches, plus the run's own."""
    return {**{k: v for k, v in environ.items() if k not in SYNC_PATH_ENV}, **server_env}


# closeGraceMs: the lag closes' close grace (#339), from the commit that added it; a run at an
# earlier commit has none, whatever params says.
SYNC_LAG_DEFAULTS = {"resyncAfterMs": 3_000, "slowConsumerCount": 3, "slowConsumerWindowMs": 60_000,
                     "ackTimeoutMs": 10_000, "ackFreshnessMs": 2_000, "closeGraceMs": 2_000}
# The load client's reconnect timing: ws-loadtest's defaults (ReconnectOption.delayMs and
# attemptTimeoutMs; cell.py passes neither), recorded in params.
RECONNECT_DELAY_MS = 1_000
RECONNECT_ATTEMPT_TIMEOUT_MS = 5_000
# Hero Defense's spawn ramp, in ticks (HERO_DEFENSE_SPAWN_RAMP_TICKS; the game's own is 3000). 0:
# every land spawns at the final rate from its first tick, so its live monster count reaches the
# plateau within the warm-up instead of growing through the measured segments (#425). Recorded
# in params; meta records what the server reported it ran with.
SPAWN_RAMP_TICKS = 0
SPAWN_RAMP_LINE = re.compile(r"GameServer effective spawnRampTicks=(-?\d+)")


class StepFailed(RuntimeError):
    def __init__(self, step: str, message: str):
        super().__init__(f"step {step} failed: {message}")
        self.step = step


class Stopped(StepFailed):
    """A TERM, INT or HUP during the run. Raised by the signal handler, so the run's `finally`
    (stop every process group, `impair.sh teardown`, record) still runs, where Python's default
    TERM action would exit without it and leave the clients, the server, the samplers and the
    qdiscs behind."""

    def __init__(self, signum: int):
        super().__init__("stopped", f"signal {signal.Signals(signum).name} received")
        self.signum = signum


STOP_SIGNALS = tuple(getattr(signal, n) for n in ("SIGTERM", "SIGINT", "SIGHUP") if hasattr(signal, n))


class StopGuard:
    """The run's stop signals (STOP_SIGNALS).

    The first stop ignores the rest: Ctrl-C, or a TERM to run.sh's process group, reaches both
    run.sh and cell.py, and run.sh passes it on, so a second Stopped raised while the first one
    unwinds would skip the teardown. While a child is being started and recorded (`held`), a stop
    only records itself (the first one wins) and is raised when the block ends, so the teardown
    reaches every child it started. The signals aren't ignored inside `held`: a child started there
    would inherit the ignore (it survives exec), and the teardown's TERM would then reach it only
    as a KILL after the grace."""

    def __init__(self, signals: tuple = STOP_SIGNALS):
        self.signals = signals
        self.is_held = False
        self.pending: int | None = None

    def install(self) -> None:
        for s in self.signals:
            signal.signal(s, self.on_signal)

    def ignore(self) -> None:
        for s in self.signals:
            signal.signal(s, signal.SIG_IGN)

    def on_signal(self, signum, frame=None) -> None:
        if self.is_held:
            self.pending = self.pending or signum
            return
        self.ignore()
        raise Stopped(signum)

    @contextlib.contextmanager
    def held(self):
        self.is_held = True
        try:
            yield
        finally:
            self.is_held = False
            if self.pending is not None:
                self.ignore()
                raise Stopped(self.pending)


def stop_group(p: subprocess.Popen, grace: float) -> None:
    """Stops the process group `p` leads (each child is started in its own session): TERM, then
    KILL after `grace` seconds. Members that outlive their leader (a shell's workers) are stopped
    too: the group is signalled even when the leader has already exited."""
    def alive() -> bool:
        try:
            os.killpg(p.pid, 0)
            return True
        except (ProcessLookupError, PermissionError):
            return False
    if not alive():
        p.poll()
        return
    os.killpg(p.pid, signal.SIGTERM)
    deadline = time.time() + grace
    while time.time() < deadline and alive():
        p.poll()
        time.sleep(0.1)
    if alive():
        os.killpg(p.pid, signal.SIGKILL)
    try:
        p.wait(10)
    except subprocess.TimeoutExpired:
        pass


def socket_path(instance: str) -> str:
    return f"/tmp/sst-ctl-{instance}.sock"


def sha256(path: str) -> str:
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def pinned(cpus: str, argv: list[str]) -> list[str]:
    return (["taskset", "-c", cpus] if cpus else []) + argv


def in_ns(ns: str, argv: list[str]) -> list[str]:
    return ["ip", "netns", "exec", ns] + argv


def existing_namespaces() -> list[str]:
    done = subprocess.run(["ip", "netns", "list"], capture_output=True, text=True)
    names = {line.split()[0] for line in done.stdout.splitlines() if line.strip()}
    return [ns for ns in NAMESPACES if ns in names]


def timewait_count() -> int:
    query = ["ss", "-tanH", "state", "time-wait", "( sport = :8080 or dport = :8080 )"]
    total = 0
    for ns in [None] + existing_namespaces():
        done = subprocess.run(query if ns is None else in_ns(ns, query), capture_output=True, text=True)
        total += sum(1 for line in done.stdout.splitlines() if line.strip())
    return total


def wait_timewait(log) -> dict:
    started = time.time()
    count = timewait_count()
    log(f"TIME_WAIT={count}")
    while count > TIMEWAIT_MAX:
        if time.time() - started > TIMEWAIT_TIMEOUT_S:
            raise StepFailed("timewait", f"TIME_WAIT {count} > {TIMEWAIT_MAX} after {TIMEWAIT_TIMEOUT_S} s")
        time.sleep(2)
        count = timewait_count()
    return {"count": count, "waitedS": round(time.time() - started)}


def up() -> bool:
    try:
        urllib.request.urlopen(HEALTH_URL, timeout=1)
        return True
    except OSError:
        return False


def instance_report(out: pathlib.Path, instance: str) -> dict | None:
    reports = sorted((out / "load" / instance).glob("ws-loadtest-*.json"))
    return json.loads(reports[-1].read_text()) if reports else None


def join_forms(report: dict | None) -> dict | None:
    """The instance's joins per wire form over its phases (ws-loadtest phaseTotals.stateUpdateFeatures)."""
    if report is None:
        return None
    merged, seen = {}, False
    for phase in report.get("phases") or []:
        counts = (phase.get("phaseTotals") or {}).get("stateUpdateFeatures")
        if counts is not None:
            seen = True
            for key, n in counts.items():
                merged[key] = merged.get(key, 0) + n
    return merged if seen else None


def loop_delay_p99(report: dict | None) -> float | None:
    """The worst worker's loop-delay p99 over the run's first phase (the whole timeline)."""
    if report is None:
        return None
    phase = next((p for p in report.get("phases") or [] if p.get("name") == "preflight"), None)
    delay = ((phase or {}).get("measurement") or {}).get("clientLoopDelay") or {}
    return (delay.get("p99Ms") or {}).get("max")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cell", choices=plan.CELLS)
    ap.add_argument("repeat", type=int)
    ap.add_argument("--sweep", required=True)
    ap.add_argument("--server", required=True)
    ap.add_argument("--rooms", type=int, default=300, choices=plan.ROOMS)
    ap.add_argument("--sr-pause", type=int)
    ap.add_argument("--calibration")
    ap.add_argument("--server-cpus", default="0-7")
    ap.add_argument("--client-cpus", default="8-11")
    ap.add_argument("--out-root", type=pathlib.Path, default=TOPIC / "data")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    cell, rooms = args.cell, args.rooms
    rid = plan.run_id(args.sweep, cell, args.repeat)
    out = (args.out_root / rid).resolve()
    population, profile = plan.population(cell), plan.profile(cell)
    cal = calibration.load(args.calibration)
    sweep_form = calibration.intended_form(os.environ)
    try:
        netem = calibration.settings(cal, cell, sweep_form, calibration.overrides_from(os.environ))
    except calibration.Refused as e:
        print(f"cell.py: {rid}: refused: {e}", file=sys.stderr)
        return 3
    if profile == "SR" and cell != plan.CALIBRATION_CELL and not args.sr_pause:
        print(f"cell.py: {rid}: refused: SR needs SR_PAUSE (srpause.py: the SR calibration's maximum pause → 4010 + 10 s, design § 4)",
              file=sys.stderr)
        return 3

    scenario_source = pathlib.Path(os.environ["SCENARIO_OVERRIDE"]) if os.environ.get("SCENARIO_OVERRIDE") else plan.scenario_file(cell, rooms)
    scenario = json.loads(scenario_source.read_text())
    if cell == "SR":
        scenario = plan.with_impaired_seconds(scenario, args.sr_pause)
    tl = plan.timeline(scenario)
    apply_s = tl["warmupSeconds"] + tl["baselineSeconds"]
    impaired_s = tl["impairedSeconds"]
    converge_s = apply_s + impaired_s + tl["recoverySeconds"]
    insts = plan.instances(cell, rooms)
    run_tag = rid
    groups = plan.groups(cell, rooms, run_tag)
    roster = plan.convergence_roster(cell, rooms)
    with_good = population in ("M", "SR")
    scenario_path = out / "scenario.json"
    timeline_path = out / "impairment-timeline.json"

    setup_argv = ["bash", IMPAIR, "setup", "--limit-down", str(netem["limits"]["down"]), "--limit-up", str(netem["limits"]["up"])] + \
        (["--with-good"] if with_good else [])
    server_env = {"TRANSPORT_PROFILE_JSONL_PATH": str(out / "profile.jsonl"), "LAND_LIFECYCLE_LOG_PATH": str(out / "land-lifecycle.jsonl"),
                  "HERO_DEFENSE_STATS_PATH": str(out / "land-stats.jsonl"),
                  "HERO_DEFENSE_SPAWN_RAMP_TICKS": str(SPAWN_RAMP_TICKS),
                  "HOST": "0.0.0.0", "ENABLE_REEVALUATION": "false", "ENABLE_DEBUG_STATE_ROUTES": "true", "LOG_LEVEL": "error"}
    server_argv = pinned(args.server_cpus, [args.server])
    sockstat_argv = pinned(args.client_cpus, ["node", f"{NODE_TOOLS}/sockstat-main.js", "--out", str(out / "sockstat.jsonl"),
                                              "--netns", ",".join(["-"] + [ns for ns in NAMESPACES if ns != "lt-good" or with_good])])
    backlog_argv = pinned(args.client_cpus, ["bash", IMPAIR, "sample-backlog", "--out", str(out / "netem-backlog.jsonl")])

    def schedule_argv(start_at):
        return ["bash", IMPAIR, "schedule", profile, "--at", str(start_at + apply_s * 1000), "--for", str(impaired_s),
                "--timeline", str(timeline_path)] + (["--rate", netem["rate"]] if "rate" in netem else [])

    def client_argv(instance, spec, start_at, pid):
        argv = ["bash", LOADTEST_SCRIPT, "--scenario", os.path.relpath(scenario_path, LOADTEST), "--external-server", str(pid),
                "--external-profile", str(out / "profile.jsonl"), "--samples-dir", str(out / "samples" / instance),
                "--output-dir", str(out / "load" / instance),
                "--system-metrics-out", str(out / ("system-metrics.json" if instance == "lt-client" else f"system-metrics-{instance}.json")),
                "--stale-after", str(STALE_AFTER_S), "--reconnect", "on-server-close",
                "--reconnect-until", str(apply_s + impaired_s + RECONNECT_AFTER_LIFT_S),
                "--reconstruct", "--control-socket", socket_path(instance), "--start-at", str(start_at), "--run-id", run_tag,
                "--input-latency", "on", "--move-to-rate", "1",
                # The client's one phase holds the impairment, so its own seen-share gate would fail
                # every impaired run; the analysis judges input-to-visible per segment instead.
                "--input-latency-min-seen", "0", "--workers", str(spec["workers"])]
        if spec["slots"]:
            argv += ["--room-slots", spec["slots"]]
        # Option A: only the sampled slots rebuild their state; the convergence check covers them.
        argv += ["--reconstruct-slots", spec["reconstruct"]]
        if profile == "SR" and instance == "lt-client":
            argv += ["--slow-read", f"{apply_s}:{impaired_s}"]
        return in_ns(instance, pinned(args.client_cpus, argv))

    converge_argv = ["node", f"{NODE_TOOLS}/converge-main.js"] + \
        [x for inst in insts for x in ("--control", f"{inst}={socket_path(inst)}")] + \
        ["--admin-url", ADMIN_URL, "--api-key", API_KEY, "--deadline-s", str(CONVERGE_DEADLINE_S), "--out", str(out / "convergence.json")]

    params = {"rooms": rooms, "population": population, "cell": cell, "repeat": args.repeat,
              "limits": netem["limits"], "calibration": netem["calibration"], "convergenceRoster": roster,
              "impairedSeconds": impaired_s,
              # Sync-lag tracking at its defaults (#332), and the load client's reconnect timing.
              "syncLag": dict(SYNC_LAG_DEFAULTS),
              "reconnectDelayMs": RECONNECT_DELAY_MS, "reconnectAttemptTimeoutMs": RECONNECT_ATTEMPT_TIMEOUT_MS,
              "spawnRampTicks": SPAWN_RAMP_TICKS}
    for key in ("rate", "jitterReorders", "reorderedPct", "calibrationOverrides"):
        if key in netem:
            params[key] = netem[key]
    if profile == "SR" and cell != plan.CALIBRATION_CELL:
        params["slowReadS"] = args.sr_pause
    if os.environ.get("SCENARIO_OVERRIDE"):
        params["scenarioOverride"] = runmeta.recorded_path(str(scenario_source), os.environ.get("SCENARIO_OVERRIDE_GIVEN"), TOPIC)
    if os.environ.get("START_MARGIN_S"):
        params["startMarginS"] = START_MARGIN_S

    if args.dry_run:
        print(f"# {rid}: {cell} repeat {args.repeat}, {rooms} rooms, profile {profile}, impaired {impaired_s} s, "
              f"limits {netem['limits']['down']}/{netem['limits']['up']}" + (f", rate {netem['rate']}" if "rate" in netem else "")
              + f", calibration {netem['calibration']['name']}" + (f", overrides {netem['calibrationOverrides']}" if "calibrationOverrides" in netem else ""))
        print(f"+ step timewait: wait until TIME_WAIT on :8080 over -,{','.join(NAMESPACES)} <= {TIMEWAIT_MAX} (at most {TIMEWAIT_TIMEOUT_S} s)")
        print(f"+ step sockets: rm -f {' '.join(socket_path(i) for i in ('lt-client', 'lt-good'))}")
        print(f"+ step setup: {shlex.join(setup_argv)}")
        print(f"+ step server: unset {' '.join(SYNC_PATH_ENV)}; {' '.join(f'{k}={v}' for k, v in server_env.items())} {shlex.join(server_argv)} &")
        print(f"+ step samplers: {shlex.join(sockstat_argv)} &; {shlex.join(backlog_argv)} &")
        print(f"+ step schedule: {shlex.join(schedule_argv(0)).replace(' --at ' + str(apply_s * 1000), f' --at <start+{apply_s}s>')} &")
        for inst, spec in insts.items():
            print(f"+ step clients: (cd {LOADTEST} && {shlex.join(client_argv(inst, spec, '<start>', '<server pid>'))}) &")
        print(f"+ step converge: at <start+{converge_s}s>: (cd {LOADTEST} && {shlex.join(converge_argv)})")
        print("+ step finish: wait for the clients and the schedule; stop the samplers and the server")
        print(f"+ step teardown: bash {IMPAIR} teardown")
        print(f"+ step record: {out}/run.json params {json.dumps(params, sort_keys=True)}")
        print(f"+ step record: groups {json.dumps({g: {k: v for k, v in s.items() if k != 'lands'} for g, s in groups.items()}, sort_keys=True)}")
        return 0

    if out.exists() and os.environ.get("OVERWRITE") != "1":
        print(f"cell.py: {out} exists (set OVERWRITE=1 to redo this run)", file=sys.stderr)
        return 1
    out.mkdir(parents=True, exist_ok=True)
    scenario_path.write_text(json.dumps(scenario, indent=2) + "\n")
    meta = json.loads((args.out_root / args.sweep / "run.json").read_text()) if (args.out_root / args.sweep / "run.json").exists() else {}
    meta = {k: meta.get(k) for k in ("runId", "git", "swiftVersion", "nodeVersion", "buildConfig", "pinCpus", "build", "gameserverBin")}
    meta.update(sweep=args.sweep, impairSha256=sha256(IMPAIR), serverCpus=args.server_cpus, clientCpus=args.client_cpus, steps={})
    # The server inherits this environment: the send-backlog bound's variables, set or null. The
    # sweep runs the shipped defaults, so regenerate.py, stopcheck.py and srpause.py refuse a set one.
    meta["sendBacklogEnv"] = {k: os.environ.get(k) or None for k in SEND_BACKLOG_ENV}
    # The same for sync-lag tracking's thresholds: the sweep runs its defaults (params.syncLag).
    meta["syncLagEnv"] = {k: os.environ.get(k) or None for k in SYNC_LAG_ENV}
    # The sync-path switches the shell had; the server ran without them (server_environ).
    meta["syncPathEnv"] = {k: os.environ.get(k) or None for k in SYNC_PATH_ENV}
    record = {"meta": meta, "params": params, "groups": groups}

    def save():
        (out / "run.json").write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")

    def log(message):
        print(f"{rid}: {message}", flush=True)

    procs: dict[str, subprocess.Popen] = {}
    server = None
    setup_done = False
    failure = None

    guard = StopGuard()
    held = guard.held
    guard.install()
    try:
        log("step timewait")
        meta["steps"]["timewait"] = wait_timewait(log)
        log("step sockets")
        for inst in ("lt-client", "lt-good"):
            pathlib.Path(socket_path(inst)).unlink(missing_ok=True)
        log("step setup")
        # Torn down even when setup fails: a partial setup can leave namespaces behind.
        setup_done = True
        done = subprocess.run(setup_argv, cwd=LOADTEST, capture_output=True, text=True)
        (out / "impair-setup.log").write_text(done.stdout + done.stderr)
        if done.returncode != 0:
            raise StepFailed("setup", f"impair.sh setup exited {done.returncode}; see impair-setup.log")
        log("step server")
        if up():
            raise StepFailed("server", "port 8080 already answers: stop that server first")
        with held():
            server = subprocess.Popen(server_argv, cwd=GAMEDEMO, env=server_environ(os.environ, server_env),
                                      stdout=open(out / "server.log", "w"), stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.time() + 60
        while not up():
            if server.poll() is not None or time.time() > deadline:
                raise StepFailed("server", f"GameServer didn't answer {HEALTH_URL} within 60 s; see server.log")
            time.sleep(0.25)
        meta["steps"]["server"] = {"pid": server.pid}
        start_at = int((time.time() + START_MARGIN_S) * 1000)
        meta["startAt"] = start_at
        save()
        log("step samplers")
        with held():
            procs["sockstat"] = subprocess.Popen(sockstat_argv, cwd=LOADTEST, stdout=open(out / "sockstat.log", "w"),
                                                 stderr=subprocess.STDOUT, start_new_session=True)
        with held():
            procs["backlog"] = subprocess.Popen(backlog_argv, cwd=LOADTEST, stdout=open(out / "netem-backlog.log", "w"),
                                                stderr=subprocess.STDOUT, start_new_session=True)
        log("step schedule")
        with held():
            procs["schedule"] = subprocess.Popen(schedule_argv(start_at), cwd=LOADTEST, stdout=open(out / "schedule.log", "w"),
                                                 stderr=subprocess.STDOUT, start_new_session=True)
        log("step clients")
        client_env = dict(os.environ, WS_LOADTEST_SKIP_BUILD="1")
        for inst, spec in insts.items():
            with held():
                procs[inst] = subprocess.Popen(client_argv(inst, spec, start_at, server.pid), cwd=LOADTEST, env=client_env,
                                               stdout=open(out / f"loadtest-{inst}.log", "w"), stderr=subprocess.STDOUT,
                                               start_new_session=True)
        converge_at = start_at / 1000 + converge_s
        while time.time() < converge_at:
            for name in list(insts) + ["schedule"]:
                p = procs[name]
                if p.poll() is not None and (name != "schedule" or p.returncode != 0):
                    raise StepFailed("clients" if name != "schedule" else "schedule",
                                     f"{name} exited ({p.returncode}) before the convergence check; see its log")
            if server.poll() is not None:
                raise StepFailed("server", f"GameServer exited ({server.returncode}) during the run; see server.log")
            time.sleep(0.5)
        log("step converge")
        conv = subprocess.run(converge_argv, cwd=LOADTEST, capture_output=True, text=True)
        meta["steps"]["converge"] = {"exitCode": conv.returncode, "stderr": conv.stderr[-2000:]}
        save()
        log("step finish")
        for inst in insts:
            procs[inst].wait()
            meta["steps"][f"client-{inst}"] = {"exitCode": procs[inst].returncode}
        procs["schedule"].wait()
        meta["steps"]["schedule"] = {"exitCode": procs["schedule"].returncode}
        if procs["schedule"].returncode != 0:
            raise StepFailed("schedule", f"impair.sh schedule exited {procs['schedule'].returncode}; see schedule.log")
    except StepFailed as e:
        failure = e
    finally:
        # A second signal must not cut the teardown short.
        guard.ignore()
        if isinstance(failure, Stopped):
            log(f"stopping: {failure}")
        for name in ("sockstat", "backlog", *insts, "schedule"):
            p = procs.get(name)
            if p is not None:
                stop_group(p, 15)
        if server is not None:
            stop_group(server, 30)
        if server is not None:
            meta["steps"]["server"] = {"pid": server.pid, "exitCode": server.returncode}
            # The ramp the server says it ran with (its startup line); None from a build without it.
            found = SPAWN_RAMP_LINE.search((out / "server.log").read_text(errors="replace")) if (out / "server.log").exists() else None
            meta["spawnRampTicksEffective"] = int(found.group(1)) if found else None
        if setup_done:
            log("step teardown")
            down = subprocess.run(["bash", IMPAIR, "teardown"], cwd=LOADTEST, capture_output=True, text=True)
            meta["steps"]["teardown"] = {"exitCode": down.returncode}
            if down.returncode != 0 and failure is None:
                failure = StepFailed("teardown", f"impair.sh teardown exited {down.returncode}: {down.stderr[-500:]}")
        log("step record")
        meta["wireForms"] = {}
        for inst in insts:
            report = instance_report(out, inst)
            meta["wireForms"][inst] = join_forms(report)
            for g in groups.values():
                if g["instance"] == inst:
                    g["loopDelayP99Ms"] = loop_delay_p99(report)
        # The client's own load per segment, on the recorded client mask (clientload.py).
        meta["clientCpu"], meta["clientElu"], meta["clientLoadMissing"] = clientload.measure(
            out, {inst: spec["workers"] for inst, spec in insts.items()}, args.client_cpus)
        if failure is not None:
            meta["failure"] = {"step": failure.step, "message": str(failure)}
        save()
    if failure is not None:
        print(f"cell.py: {rid}: {failure}", file=sys.stderr)
        return 128 + failure.signum if isinstance(failure, Stopped) else 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
