#!/usr/bin/env python3
"""Convert raw/<tag>.json (EncodingBenchmark scalability-matrix output) into one
results/<run-id>.json per cell, following the experiment-artifacts contract.

A sweep from run.sh writes raw/<RUN_ID>/<tag>.json with its record raw/<RUN_ID>/run.json;
each of its cells becomes results/<run-id>-rep<n>.json, with the record's repeat and order in
``params`` (``repeat``, ``order``, ``sweep``). The repeat and order come from run.json only,
never from a directory name or a time. Two sweeps that claim the same repeat are refused unless
all but one are marked superseded (``runmeta.py supersede``). Files directly in raw/ (the first,
unrepeated sweep) have no ``repeat``.

A sweep's results carry ``meta.git_dirty`` from its run.json (``git.dirty``, written by
runmeta.py); a sweep whose run.json doesn't record it as true or false is refused. The tracked
files directly in raw/ predate the record and carry no flag (regenerate.py grandfathers their
commits)."""
import json, pathlib, re

TOPIC = pathlib.Path(__file__).parent
RAW, RES = TOPIC / "raw", TOPIC / "results"
RES.mkdir(exist_ok=True)

def recorded_commit(raw, meta):
    """The commit the raw file's own run recorded (EncodingBenchmark metadata `git.commit`),
    abbreviated as the published results are. Never the checkout's HEAD: collect also converts the
    tracked record in raw/, whose commit is its own."""
    commit = (meta.get("git") or {}).get("commit")
    if not isinstance(commit, str) or len(commit) < 7:
        raise SystemExit(f"{raw}: no commit recorded (metadata.git.commit); can't attribute its results")
    return commit[:7]

def raw_files():
    """(path, sweep record or None) for every raw cell file; ``<tag>.views.json`` gate reports aren't cells."""
    for raw in sorted(RAW.glob("*.json")):
        if not raw.name.endswith(".views.json"):
            yield raw, None
    sweeps = {}
    for record_path in sorted(RAW.glob("*/run.json")):
        record = json.loads(record_path.read_text())
        if record.get("superseded"):
            continue
        if record["repeat"] in sweeps:
            raise SystemExit(f"repeat {record['repeat']} is claimed by both {sweeps[record['repeat']][0].parent.name} "
                             f"and {record_path.parent.name}; mark one superseded (runmeta.py supersede)")
        sweeps[record["repeat"]] = (record_path, record)
    for record_path, record in sorted(sweeps.values(), key=lambda s: s[1]["repeat"]):
        for raw in sorted(record_path.parent.glob("*.json")):
            if raw.name != "run.json" and not raw.name.endswith(".views.json"):
                yield raw, record

def recorded_dirty(raw, sweep):
    """The sweep's ``git.dirty`` from its run.json: true or false, else refused."""
    dirty = (sweep.get("git") or {}).get("dirty")
    if not isinstance(dirty, bool):
        raise SystemExit(f"{raw.parent / 'run.json'}: no git.dirty recorded (got {dirty!r}); "
                         "run the sweep with this topic's run.sh, whose runmeta.py records git.dirty in run.json")
    return dirty

legacy = "USE_SNAPSHOT_FOR_SYNC=false"
for raw, sweep in raw_files():
    repeat = None if sweep is None else sweep["repeat"]
    d = json.load(open(raw))
    meta, cmd = d["metadata"], d["metadata"]["commandLine"]
    strategy = cmd[cmd.index("--sync-strategy") + 1] if "--sync-strategy" in cmd else "delta"
    active = "--active-players" in cmd
    cap = int(cmd[cmd.index("--monster-cap") + 1]) if "--monster-cap" in cmd else None
    encoding = cmd[cmd.index("--format") + 1]
    axis = ("rooms" if raw.stem.startswith("rq1-rooms") else "rooms-large" if raw.stem.startswith("rq2-rooms")
            else "active" if raw.stem.startswith("active") else "monsters")
    for r in d["results"]:
        rooms, players = r["rooms"], r["playersPerRoom"]
        sname = "full" if strategy == "full-snapshot" else "delta"
        enc = "json" if encoding == "json-object" else "msgpack"
        run_id = (f"{axis}-p{players}-r{rooms}" + (f"-cap{cap}" if cap is not None else "") + f"-{enc}-{sname}"
                  + (f"-rep{repeat}" if repeat is not None else ""))
        env = meta.get("environment", {})
        # Runs with both modes report the parallel half (the original matrix); a single-mode run
        # (`--parallel false`, the serial rerun) has only its own half.
        mode = r.get("config", {}).get("mode", "both")
        half = r["serial"] if mode == "serial" else r["parallel"]
        out = {
            "meta": {
                "date": meta.get("timestampUTC", ""),
                "git_sha": recorded_commit(raw, meta),
                # The wire knobs the run recorded (EncodingBenchmark metadata; None before
                # they existed): resolved and gated with deep-research/wireform.py.
                "path_index": meta.get("pathIndex"),
                "field_merge": meta.get("fieldMerge"),
                "swift_version": re.search(r"version ([\d.]+)", meta["build"]["swiftVersion"]).group(1),
                "build_config": meta["build"]["configuration"],
                "host": f"{env.get('cpuModel') or 'Apple M2'}, {env.get('osName','Darwin')} {env.get('kernelVersion','')}".strip(),
                # The unrepeated record ran with USE_SNAPSHOT_FOR_SYNC=false; a run.sh sweep records
                # the server environment it ran with (deep-research/serverenv.py).
                "command": (legacy + " " if sweep is None else "") + " ".join(["swift run -c release EncodingBenchmark"] + cmd[1:]),
                "server_env": None if sweep is None else sweep.get("serverEnv"),
                "source_file": str(raw.relative_to(RAW)),
            },
            "params": {
                "axis": axis, "sync_strategy": strategy, "players": players, "rooms": rooms,
                "monster_cap": cap, "workload": "active" if active else "idle",
                "encoding": encoding, "ticks_per_sync": 2, "iterations": 200,
                "use_snapshot_for_sync": False if sweep is None else (sweep.get("serverEnv") or {}).get("USE_SNAPSHOT_FOR_SYNC"),
            },
            "metrics": {
                # EncodingBenchmark's bytesPerSync is totalBytes / iterations in integer division
                # (BenchmarkExecution.swift), so this is truncated to whole bytes; the record and the
                # drift table's identity with single-room-entity-scaling (floor of its unrounded
                # totalBytes / iterations) depend on it staying so.
                "bytes_per_sync": float(half["bytesPerSync"]),
                "bytes_per_sync_serial": float(r["serial"]["bytesPerSync"]),
                "avg_cost_per_sync_ms": half["avgCostPerSyncMs"],
                "final_monster_count": half.get("finalMonsterCount"),
            },
        }
        if sweep is not None:
            out["params"].update(repeat=sweep["repeat"], order=sweep["order"], sweep=sweep["runId"])
            out["meta"]["git_dirty"] = recorded_dirty(raw, sweep)
        if mode != "both":
            out["params"]["sync_mode"] = mode
        json.dump(out, open(RES / f"{run_id}.json", "w"), indent=2, sort_keys=True)
        print(run_id, out["metrics"]["bytes_per_sync"], round(out["metrics"]["avg_cost_per_sync_ms"], 3))
