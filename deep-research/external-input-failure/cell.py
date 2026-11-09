#!/usr/bin/env python3
"""Runs one cell of the matrix (cells.py) and writes its raw outputs to <out>/ (stdlib only).

  cell.py <cell> <out> --server <GameServer> --runner <ReevaluationRunner> [--rooms N]
          [--pre-s S] [--steady-s S] [--tail-s S] [--server-cpus L] [--client-cpus L] [--dry-run]

One GameServer process per cell (`ENABLE_REEVALUATION=true`, `ENABLE_DEBUG_STATE_ROUTES=true`,
messagepack, the transport profiler and the tick probe on), with the cell's environment. The load
client (`scripts/run-ws-loadtest.sh --external-server`) runs a generated scenario from a fixed
`--start-at`: a warm-up phase, the steady phase, and a tail that sends nothing. In the leave cell
a second instance (`node dist/cli.js`, `--room-slots`) holds the leaving slots of every room and
runs warm-up, steady and a 1 s tail, then exits, so its players leave lands the first instance
keeps up (`load-leavers/`, `samples-leavers/`). In the first instance's tail, in this order:

1. the profiler shows no message handled for two intervals (`messagesReceived` 0: the sends
   have stopped and nothing queued is left);
   then, over the load's lines, each session's inbound queue stayed within `BACKLOG_BOUND`
   (`inboundQueuedMessagesMax`), or the cell fails: a backlog means the cell offers more than a
   session serves (cells.check);
2. drain: the `abandonedResolvers` gauge reads 0 in a profiler line after that, within the
   longest call plus 10 s (`drain.json`; past the bound the cell fails);
3. convergence: `converge-main.js` freezes every land, compares each client's state with its
   projection and resumes (`converge.json`);
4. the clients' states, read from the control socket (`client-states.json`): each land's
   `applied`, `joins` and `leaves`;
5. every land's live record (`/admin/lands/:id/reevaluation-record`).

After the load client exits, with the server still up, each record is converted to count its
actions, and `ReevaluationRunner --verify` replays every record of a run of 50 rooms or fewer, or
a seeded sample of 50 (`records.json`). The records are deleted once counted and replayed.
"""
import argparse, http.client, json, os, pathlib, random, shutil, signal, socket, subprocess, sys, time, urllib.parse, urllib.request

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC))
import cells  # noqa: E402

GAMEDEMO = TOPIC.parent.parent / "Examples" / "GameDemo"
LOADTEST = GAMEDEMO / "ws-loadtest"
ADMIN = "http://localhost:8080"
API_KEY = "hero-defense-admin-key"
LAND_TYPE = "resolver-test"
PROFILE_INTERVAL_MS = 1000
START_MARGIN_S = 40
CONVERGE_DEADLINE_S = 40
REPLAY_SAMPLE = 50
SAMPLE_SEED = 1
BACKLOG_BOUND = cells.BACKLOG_BOUND


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("control")
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self.path)


def control(sock, method, path):
    conn = UnixHTTPConnection(sock)
    conn.request(method, path)
    response = conn.getresponse()
    body = response.read()
    if response.status != 200:
        raise RuntimeError(f"control {method} {path}: {response.status} {body[:200]!r}")
    return json.loads(body)


def admin(path, out=None):
    request = urllib.request.Request(ADMIN + path, headers={"X-API-Key": API_KEY})
    with urllib.request.urlopen(request, timeout=30) as response:
        body = response.read()
    if out is not None:
        pathlib.Path(out).write_bytes(body)
        return None
    return json.loads(body)


def scenario(c, args, tail_s):
    phase = lambda seconds, aps, players: {
        "durationSeconds": seconds, "rooms": args.rooms, "playersPerRoom": players, "actionsPerSecond": aps,
        "verify": False,
        # The cell's gates are collect.py's; the client's own thresholds are open but for errors and disconnects.
        "thresholds": {"errorRate": 0, "disconnectRate": 0, "rttP95": 60000, "rttP99": 60000, "updateP95": 60000, "updateP99": 60000},
    }
    return {
        "name": f"external-input-{args.cell}",
        "serverUrl": f"ws://localhost:8080/game/{LAND_TYPE}",
        "landType": LAND_TYPE,
        "syncIntervalMs": 50,
        "actions": [{"name": "CallServiceAction", "weight": 1,
                     "payloadTemplate": {"tag": "load", "delayMs": -1, "deadlineMs": -1, "outcome": c["outcome"]}}],
        "phases": {
            "preflight": phase(args.pre_s, c["actions_per_second"], cells.PLAYERS),
            "steady": phase(args.steady_s, c["actions_per_second"], cells.PLAYERS),
            "postflight": phase(tail_s, 0, cells.PLAYERS),
        },
    }


def profile_lines(path):
    if not path.exists():
        return []
    lines = []
    for raw in path.read_text().splitlines():
        try:
            lines.append(json.loads(raw))
        except json.JSONDecodeError:
            pass  # a line still being written
    return lines


def quiet_point(lines, from_ts):
    """The first of two consecutive profiler lines from `from_ts` in which the server handled no
    message (`messagesReceived` 0), or None. Not `actions`: it counts only the actions that
    succeeded, so in a cell where every action times out it reads 0 throughout the load."""
    lines = [l for l in lines if l["ts"] >= from_ts]
    for a, b in zip(lines, lines[1:]):
        if a["counters"]["messagesReceived"] == 0 and b["counters"]["messagesReceived"] == 0:
            return a["ts"]
    return None


def queued_max(lines, start_ts, end_ts):
    """The most messages a session held read but not yet handled, over the lines in [start, end]."""
    return max((l["counters"]["inboundQueuedMessagesMax"] for l in lines if start_ts <= l["ts"] <= end_ts), default=0)


def wait_for(predicate, bound_s, what, poll_s=0.25):
    deadline = time.time() + bound_s
    while time.time() < deadline:
        value = predicate()
        if value is not None:
            return value
        time.sleep(poll_s)
    raise TimeoutError(f"{what}: not within {bound_s:.0f} s")


def pinned(cpus, argv):
    return (["taskset", "-c", cpus] if cpus else []) + argv


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cell", choices=sorted(cells.CELLS))
    ap.add_argument("out", type=pathlib.Path)
    ap.add_argument("--server", required=True)
    ap.add_argument("--runner", required=True)
    ap.add_argument("--rooms", type=int)
    ap.add_argument("--pre-s", type=int, default=cells.PRE_S)
    ap.add_argument("--steady-s", type=int, default=cells.STEADY_S)
    ap.add_argument("--tail-s", type=int, default=cells.TAIL_S)
    ap.add_argument("--server-cpus", default="")
    ap.add_argument("--client-cpus", default="")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    c = cells.CELLS[args.cell]
    args.rooms = args.rooms or c["rooms"]
    out = args.out.resolve()
    profile, probe = out / "transport-profile.jsonl", out / "tick-probe.jsonl"
    records = out / ".records"
    sock = f"/tmp/sst-ei-{os.getpid()}.sock"
    env = dict(os.environ, **c["env"], ENABLE_REEVALUATION="true", ENABLE_DEBUG_STATE_ROUTES="true",
               TRANSPORT_ENCODING="messagepack", LOG_LEVEL="error", NO_COLOR="1",
               TRANSPORT_PROFILE_JSONL_PATH=str(profile), TRANSPORT_PROFILE_INTERVAL_MS=str(PROFILE_INTERVAL_MS),
               RESOLVER_TEST_TICK_PROBE_PATH=str(probe), REEVALUATION_RECORDS_DIR=str(out / ".spool"))
    server_argv = pinned(args.server_cpus, [args.server])
    scenario_path, leavers_path = out / "scenario.json", out / "scenario-leavers.json"
    stay = cells.PLAYERS - c["leavers"]
    slots = (["--room-slots", f"0-{args.rooms - 1}:0-{stay - 1}"] if c["leavers"] else [])
    leavers_argv = lambda start_at: pinned(args.client_cpus, [
        "node", "dist/cli.js", "--scenario", str(leavers_path), "--output-dir", str(out / "load-leavers"),
        "--samples-dir", str(out / "samples-leavers"), "--room-slots", f"0-{args.rooms - 1}:{stay}-{cells.PLAYERS - 1}",
        "--start-at", str(start_at), "--run-id", args.cell])
    load_argv = lambda start_at, pid: pinned(args.client_cpus, [
        "bash", "scripts/run-ws-loadtest.sh", "--scenario", os.path.relpath(scenario_path, LOADTEST),
        "--external-server", str(pid), "--external-profile", str(profile), "--output-dir", str(out / "load"),
        "--samples-dir", str(out / "samples"), "--system-metrics-out", str(out / "system-metrics.json"),
        "--reconstruct", "--control-socket", sock, "--start-at", str(start_at), "--run-id", args.cell,
    ] + slots + (["--allow-join-failures"] if float(c["env"]["RESOLVER_TEST_JOIN_FAILURE_RATE"]) > 0 else []))
    converge_argv = ["node", "dist/converge-main.js", "--control", f"ei={sock}", "--admin-url", ADMIN, "--api-key", API_KEY,
                     "--deadline-s", str(CONVERGE_DEADLINE_S), "--land-type", LAND_TYPE, "--out", str(out / "converge.json")]
    if args.dry_run:
        shown = {k: c["env"][k] for k in sorted(c["env"])}
        print(f"+ {' '.join(f'{k}={v}' for k, v in shown.items())} ENABLE_REEVALUATION=true ENABLE_DEBUG_STATE_ROUTES=true "
              f"{' '.join(server_argv)} &   # profiler + tick probe -> {out}/")
        print(f"+ (cd {LOADTEST} && {' '.join(load_argv('<now+%ds>' % START_MARGIN_S, '<server pid>'))}) &   "
              f"# {args.rooms} rooms x {cells.PLAYERS}, {args.pre_s}+{args.steady_s}+{args.tail_s} s")
        if c["leavers"]:
            print(f"+ (cd {LOADTEST} && {' '.join(leavers_argv('<same start>'))}) &   # {c['leavers']} per room leave after steady")
        print(f"+ wait: no message handled for 2 profiler intervals; inbound queue <= {BACKLOG_BOUND} per session; "
              "then abandonedResolvers 0 within "
              f"{(cells.longest_call_ms(c) + 10000) / 1000:g} s")
        print(f"+ (cd {LOADTEST} && {' '.join(converge_argv)})")
        print(f"+ GET {sock} /lands?states=...  -> {out}/client-states.json; GET /admin/lands/:id/reevaluation-record x{args.rooms}")
        print(f"+ {args.runner} --convert x{args.rooms}; {args.runner} --input <record> --verify x{min(args.rooms, REPLAY_SAMPLE)}")
        print("+ stop the server")
        return
    out.mkdir(parents=True, exist_ok=True)
    scenario_path.write_text(json.dumps(scenario(c, args, args.tail_s), indent=2) + "\n")
    if c["leavers"]:
        leavers_path.write_text(json.dumps(scenario(c, args, 1), indent=2) + "\n")
    meta = {"cell": args.cell, "spec": c, "rooms": args.rooms, "preS": args.pre_s, "steadyS": args.steady_s, "tailS": args.tail_s,
            "serverCpus": args.server_cpus, "clientCpus": args.client_cpus, "steps": {}}

    def save():
        (out / "cell.json").write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n")

    def fail(message):
        meta["failure"] = message
        save()
        sys.exit(f"{args.cell}: {message}")

    try:
        urllib.request.urlopen(ADMIN + "/schema", timeout=1)
        fail("port 8080 already answers: stop that server first")
    except OSError:
        pass
    server = subprocess.Popen(server_argv, cwd=GAMEDEMO, env=env, stdout=open(out / "server.log", "w"), stderr=subprocess.STDOUT)
    load = leavers = None
    try:
        wait_for(lambda: True if _up() else None, 60, "server start")
        start_at = int((time.time() + START_MARGIN_S) * 1000)
        meta["startAt"] = start_at
        save()
        load = subprocess.Popen(load_argv(start_at, server.pid), cwd=LOADTEST, stdout=open(out / "loadtest.log", "w"),
                                stderr=subprocess.STDOUT)
        if c["leavers"]:
            leavers = subprocess.Popen(leavers_argv(start_at), cwd=LOADTEST, stdout=open(out / "loadtest-leavers.log", "w"),
                                       stderr=subprocess.STDOUT)
        # The tail starts after warm-up, steady and the connect ramp (1000 connections per second).
        tail_at = start_at / 1000 + args.pre_s + args.steady_s + args.rooms * cells.PLAYERS / 1000 + 1
        while time.time() < tail_at:
            if load.poll() is not None:
                fail(f"load client exited ({load.returncode}) before the tail; see loadtest.log")
            time.sleep(0.5)

        if leavers is not None:
            try:
                leavers.wait(60)
            except subprocess.TimeoutExpired:
                fail("the leaving instance didn't exit within 60 s of the tail")
            meta["steps"]["leavers"] = {"exitCode": leavers.returncode, "exitedAt": int(time.time() * 1000)}
            save()

        quiet_ts = wait_for(lambda: quiet_point(profile_lines(profile), tail_at * 1000), 15, "the sends stopping")
        meta["steps"]["quiet"] = {"quietTs": quiet_ts, "tailAt": int(tail_at * 1000)}
        backlog = queued_max(profile_lines(profile), start_at, quiet_ts)
        meta["steps"]["backlog"] = {"queuedMessagesMax": backlog, "bound": BACKLOG_BOUND}
        save()
        if backlog > BACKLOG_BOUND:
            fail(f"a session queued {backlog} messages (bound {BACKLOG_BOUND}): the cell offers more than a session serves")
        bound_ms = cells.longest_call_ms(c) + 10000

        def drained():
            for l in profile_lines(profile):
                if l["ts"] > quiet_ts and l["counters"]["abandonedResolvers"] == 0:
                    return l["ts"]
            return None
        try:
            drain_ts = wait_for(drained, bound_ms / 1000 + 2, "drain")
        except TimeoutError:
            meta["steps"]["drain"] = {"quietTs": quiet_ts, "boundMs": bound_ms, "zeroTs": None}
            fail(f"abandonedResolvers didn't read 0 within {bound_ms} ms")
        meta["steps"]["drain"] = {"quietTs": quiet_ts, "boundMs": bound_ms, "zeroTs": drain_ts}
        save()
        converge = subprocess.run(converge_argv, cwd=LOADTEST, capture_output=True, text=True)
        meta["steps"]["converge"] = {"exitCode": converge.returncode, "stderr": converge.stderr[-2000:]}
        save()
        lands = sorted(l for l in admin("/admin/lands")["data"] if l.startswith(LAND_TYPE + ":"))
        # The load client names a land without its type prefix.
        query = "&".join("states=" + urllib.parse.quote(l.split(":", 1)[1], safe="") for l in lands)
        states = control(sock, "GET", "/lands?" + query)
        meta["steps"]["states"] = {"readAt": int(time.time() * 1000), "lands": len(lands)}
        (out / "client-states.json").write_text(json.dumps(states) + "\n")
        records.mkdir(exist_ok=True)
        for i, land in enumerate(lands):
            admin(f"/admin/lands/{urllib.parse.quote(land, safe='')}/reevaluation-record", records / f"room-{i}.sstr")
        meta["steps"]["records"] = {"downloadedAt": int(time.time() * 1000), "lands": lands}
        if load.poll() is not None:
            fail("the load client ended before the records were read (the tail is too short)")
        save()
        load.wait()
        meta["steps"]["load"] = {"exitCode": load.returncode}
        save()
    finally:
        for proc in (load, leavers):
            if proc is not None and proc.poll() is None:
                proc.terminate()
        server.send_signal(signal.SIGTERM)
        try:
            server.wait(30)
        except subprocess.TimeoutExpired:
            server.kill()
        meta.setdefault("steps", {})["server"] = {"exitCode": server.returncode}
        save()
    # Count each record's actions, and replay all of them or a seeded sample.
    lands = meta["steps"]["records"]["lands"]
    replayed = set(range(len(lands))) if len(lands) <= REPLAY_SAMPLE else set(random.Random(SAMPLE_SEED).sample(range(len(lands)), REPLAY_SAMPLE))
    result = {}
    for i, land in enumerate(lands):
        sstr, view = records / f"room-{i}.sstr", records / f"room-{i}.json"
        subprocess.run([args.runner, "--convert", str(sstr), str(view)], cwd=GAMEDEMO, env=env, check=True, capture_output=True)
        frames = json.loads(view.read_text())["tickFrames"]
        entry = {"recordedActions": sum(len(f["actions"]) for f in frames), "replayed": i in replayed}
        if i in replayed:
            proc = subprocess.run([args.runner, "--input", str(sstr), "--verify"], cwd=GAMEDEMO, env=env, capture_output=True, text=True)
            lines = [l.strip() for l in (proc.stdout + proc.stderr).splitlines()]
            sync = next((l for l in lines if l.startswith("Sync Output:")), None)
            entry.update(exitCode=proc.returncode, syncOutput=sync,
                         passed=proc.returncode == 0 and sync is not None and sync.startswith("Sync Output: passed"))
        result[land] = entry
        sstr.unlink()
        view.unlink()
    (out / "records.json").write_text(json.dumps(result, indent=1, sort_keys=True) + "\n")
    records.rmdir()
    shutil.rmtree(out / ".spool", ignore_errors=True)
    meta["done"] = True
    save()


def _up():
    try:
        urllib.request.urlopen(ADMIN + "/schema", timeout=1)
        return True
    except OSError:
        return False


if __name__ == "__main__":
    main()
