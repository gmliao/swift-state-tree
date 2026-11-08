#!/usr/bin/env python3
"""Convert raw/<tag>.json (EncodingBenchmark scalability-matrix output) into one
results/<run-id>.json per cell, following the experiment-artifacts contract.

A sweep from run.sh writes raw/<RUN_ID>/<tag>.json with its record raw/<RUN_ID>/run.json;
each of its cells becomes results/<run-id>-rep<n>.json, with the record's repeat and order in
``params`` (``repeat``, ``order``, ``sweep``). The repeat and order come from run.json only,
never from a directory name or a time. Two sweeps that claim the same repeat are refused unless
all but one are marked superseded (``runmeta.py supersede``). Files directly in raw/ (the first,
unrepeated sweep) have no ``repeat``."""
import json, pathlib, re, subprocess, platform

TOPIC = pathlib.Path(__file__).parent
RAW, RES = TOPIC / "raw", TOPIC / "results"
RES.mkdir(exist_ok=True)

def sha():
    return subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True, cwd=TOPIC).stdout.strip()

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
                "git_sha": sha(),
                # The wire knobs the run recorded (EncodingBenchmark metadata; None before
                # they existed): resolved and gated with deep-research/wireform.py.
                "path_index": meta.get("pathIndex"),
                "field_merge": meta.get("fieldMerge"),
                "swift_version": re.search(r"version ([\d.]+)", meta["build"]["swiftVersion"]).group(1),
                "build_config": meta["build"]["configuration"],
                "host": f"{env.get('cpuModel') or 'Apple M2'}, {env.get('osName','Darwin')} {env.get('kernelVersion','')}".strip(),
                "command": "USE_SNAPSHOT_FOR_SYNC=false " + " ".join(["swift run -c release EncodingBenchmark"] + cmd[1:]),
                "source_file": str(raw.relative_to(RAW)),
            },
            "params": {
                "axis": axis, "sync_strategy": strategy, "players": players, "rooms": rooms,
                "monster_cap": cap, "workload": "active" if active else "idle",
                "encoding": encoding, "ticks_per_sync": 2, "iterations": 200,
                "use_snapshot_for_sync": False,
            },
            "metrics": {
                "bytes_per_sync": float(half["bytesPerSync"]),
                "bytes_per_sync_serial": float(r["serial"]["bytesPerSync"]),
                "avg_cost_per_sync_ms": half["avgCostPerSyncMs"],
                "final_monster_count": half.get("finalMonsterCount"),
            },
        }
        if sweep is not None:
            out["params"].update(repeat=sweep["repeat"], order=sweep["order"], sweep=sweep["runId"])
        if mode != "both":
            out["params"]["sync_mode"] = mode
        json.dump(out, open(RES / f"{run_id}.json", "w"), indent=2, sort_keys=True)
        print(run_id, out["metrics"]["bytes_per_sync"], round(out["metrics"]["avg_cost_per_sync_ms"], 3))
