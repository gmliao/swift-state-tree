#!/usr/bin/env python3
"""Convert raw/<tag>.json (EncodingBenchmark scalability-matrix output) into one
results/<run-id>.json per cell, following the experiment-artifacts contract."""
import json, pathlib, re, subprocess, platform

TOPIC = pathlib.Path(__file__).parent
RAW, RES = TOPIC / "raw", TOPIC / "results"
RES.mkdir(exist_ok=True)

def sha():
    return subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True, cwd=TOPIC).stdout.strip()

for raw in sorted(RAW.glob("*.json")):
    d = json.load(open(raw))
    meta, cmd = d["metadata"], d["metadata"]["commandLine"]
    strategy = cmd[cmd.index("--sync-strategy") + 1] if "--sync-strategy" in cmd else "delta"
    active = "--active-players" in cmd
    cap = int(cmd[cmd.index("--monster-cap") + 1]) if "--monster-cap" in cmd else None
    axis = raw.stem.rsplit("-", 1)[0] if strategy == "delta" else raw.stem[: -len("-full-snapshot")]
    axis = {"rq1-rooms": "rooms", "active-players": "active"}.get(axis, "monsters")
    for r in d["results"]:
        rooms, players = r["rooms"], r["playersPerRoom"]
        sname = "full" if strategy == "full-snapshot" else "delta"
        run_id = f"{axis}-p{players}-r{rooms}" + (f"-cap{cap}" if cap is not None else "") + f"-{sname}"
        env = meta.get("environment", {})
        out = {
            "meta": {
                "date": meta.get("timestampUTC", ""),
                "git_sha": sha(),
                "swift_version": re.search(r"version ([\d.]+)", meta["build"]["swiftVersion"]).group(1),
                "build_config": meta["build"]["configuration"],
                "host": f"{env.get('cpuModel') or 'Apple M2'}, {env.get('osName','Darwin')} {env.get('kernelVersion','')}".strip(),
                "command": "USE_SNAPSHOT_FOR_SYNC=false " + " ".join(["swift run -c release EncodingBenchmark"] + cmd[1:]),
                "source_file": raw.name,
            },
            "params": {
                "axis": axis, "sync_strategy": strategy, "players": players, "rooms": rooms,
                "monster_cap": cap, "workload": "active" if active else "idle",
                "encoding": "messagepack-pathhash", "ticks_per_sync": 2, "iterations": 200,
                "use_snapshot_for_sync": False,
            },
            "metrics": {
                "bytes_per_sync": float(r["parallel"]["bytesPerSync"]),
                "bytes_per_sync_serial": float(r["serial"]["bytesPerSync"]),
                "avg_cost_per_sync_ms": r["parallel"]["avgCostPerSyncMs"],
                "final_monster_count": r["parallel"].get("finalMonsterCount"),
            },
        }
        json.dump(out, open(RES / f"{run_id}.json", "w"), indent=2, sort_keys=True)
        print(run_id, out["metrics"]["bytes_per_sync"], round(out["metrics"]["avg_cost_per_sync_ms"], 3))
