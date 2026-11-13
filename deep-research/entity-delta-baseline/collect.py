#!/usr/bin/env python3
"""Convert run.sh's raw outputs into one results/<run-id>.json per (cell, variant, repeat),
following the experiment-artifacts contract (stdlib only).

For every sweep raw/<RUN_ID>/ whose run.json isn't superseded, each <cell>-<variant>.json
(EncodingBenchmark scalability-matrix output) becomes one result per room count or player count
in it, with that variant's capture reports joined in: <tag>.views.json (the gate) and
<tag>.decode.json (decode timing and the bytes per room before and after deflate). The repeat and
order come from run.json only. Two sweeps that claim the same repeat are refused unless all but
one are superseded.

Usage: python3 collect.py [--raw <dir>] [--results <dir>]
"""
import argparse, hashlib, json, pathlib, re, sys

TOPIC = pathlib.Path(__file__).resolve().parent
VARIANTS = ("sst-events", "sst", "b2")
B1_VARIANTS = ("b1", "b1-tuned")


def sweeps(raw):
    """The measured sweeps, one per repeat, and the state-only ones (run.sh STATE_ONLY=1)."""
    claimed, state_only = {}, []
    for record_path in sorted(raw.glob("*/run.json")):
        record = json.loads(record_path.read_text(encoding="utf-8"))
        if record.get("superseded"):
            continue
        if record.get("stateOnly"):
            state_only.append((record_path, record))
            continue
        if record["repeat"] in claimed:
            sys.exit(f"repeat {record['repeat']} is claimed by both {claimed[record['repeat']][0].parent.name} "
                     f"and {record_path.parent.name}; mark one superseded (runmeta.py supersede)")
        claimed[record["repeat"]] = (record_path, record)
    if len(state_only) > 1:
        sys.exit(f"{len(state_only)} state-only sweeps ({', '.join(s[0].parent.name for s in state_only)}); mark all but one superseded")
    return sorted(claimed.values(), key=lambda s: s[1]["repeat"]) + state_only


def split_tag(stem):
    for variant in sorted(VARIANTS + B1_VARIANTS, key=len, reverse=True):
        if stem.endswith("-" + variant):
            return stem[: -len(variant) - 1], variant
    return None, None


def arg(cmd, flag, cast=str):
    return cast(cmd[cmd.index(flag) + 1]) if flag in cmd else None


def capture_run(report, rooms, players, cap, active):
    """The run of a capture report (verify-views or time-decode) that holds this cell's rooms."""
    if report is None:
        return None
    suffix = f"-r{rooms}-p{players}-m{cap or 0}{'-active' if active else ''}-serial"
    hits = [v for k, v in report["runs"].items() if k.endswith(suffix)]
    if len(hits) != 1:
        sys.exit(f"expected one capture run ending {suffix}, found {len(hits)}")
    return hits[0]


def collect(raw, results):
    results.mkdir(parents=True, exist_ok=True)
    written = []
    for record_path, record in sweeps(raw):
        directory = record_path.parent
        if record.get("onlyCells"):
            # A smoke sweep of a few cells (run.sh CELLS=...) isn't a repeat of the matrix.
            print(f"skipping {directory.name}: only cells {record['onlyCells']}", file=sys.stderr)
            continue
        written += collect_state(directory, record, raw, results)
        if record.get("stateOnly"):
            continue
        for path in sorted(directory.glob("*.json")):
            if path.name == "run.json" or path.name.endswith((".views.json", ".decode.json", ".projections.json", ".colyseus.json", ".state.json")):
                continue
            cell, variant = split_tag(path.stem)
            if variant is None:
                sys.exit(f"{path}: not <cell>-<variant>.json")
            d = json.loads(path.read_text(encoding="utf-8"))
            meta, cmd = d["metadata"], d["metadata"]["commandLine"]
            if ("--baseline" in cmd) != (variant == "b2") or ("--no-server-events" in cmd) != (variant != "sst-events"):
                sys.exit(f"{path}: flags {cmd} don't match variant {variant}")
            views_path, decode_path = directory / f"{path.stem}.views.json", directory / f"{path.stem}.decode.json"
            views = json.loads(views_path.read_text(encoding="utf-8")) if views_path.exists() else None
            decode = json.loads(decode_path.read_text(encoding="utf-8")) if decode_path.exists() else None
            cap, active = arg(cmd, "--monster-cap", int), "--active-players" in cmd
            iterations = arg(cmd, "--iterations", int)
            axis = "rooms" if cell == "rooms" else "active" if cell.startswith("active") else "monsters"
            for r in d["results"]:
                rooms, players, half = r["rooms"], r["playersPerRoom"], r["serial"]
                run_id = (f"{axis}-p{players}-r{rooms}" + (f"-cap{cap}" if cap is not None and axis == "monsters" else "")
                          + f"-{variant}-rep{record['repeat']}")
                metrics = {}
                if variant == "b2":
                    e = half["entityDelta"]
                    metrics.update(
                        bytes_per_sync=float(e["bytesPerSync"]),
                        first_sync_bytes=e["firstSyncBytes"],
                        bytes_per_sync_bitpacked_bound=float(e["bytesPerSyncBitpackedBound"]),
                        project_us_per_room_sync=e["projectUsPerRoomSync"],
                        encode_only_us_per_room_sync=e["encodeOnlyUsPerRoomSync"],
                        encode_us_per_room_sync=e["encodeUsPerRoomSync"],
                        encode_shared_only_us_per_room_sync=e["encodeSharedOnlyUsPerRoomSync"],
                        encode_shared_us_per_room_sync=e["encodeSharedUsPerRoomSync"],
                        encoder_state_bytes=e["encoderStateBytes"],
                        rss_delta_mib=e["rssDeltaMiB"],
                        value_writer=e["valueWriter"],
                    )
                else:
                    # The benchmark's bytesPerSync is an integer division; totalBytes / iterations
                    # is the same figure unrounded, comparable with B2's to the byte.
                    metrics.update(
                        bytes_per_sync=half["totalBytes"] / iterations,
                        sync_us_per_room_sync=half["syncMs"] * 1000 / (rooms * iterations),
                    )
                hashes_path = directory / f"{path.stem}.projections.json"
                if hashes_path.exists():
                    key = f"r{rooms}-p{players}-m{cap or 0}{'-active' if active else ''}-serial"
                    metrics["projection_sha256"] = projection_digest(hashes_path, key)
                view = capture_run(views, rooms, players, cap, active)
                timed = capture_run(decode, rooms, players, cap, active)
                if view is not None:
                    # A room passes when every recipient decoded every frame and matched after every sync.
                    metrics["gate_passed"] = all(room["decodeErrors"] == 0 and not room["differences"] for room in view)
                    metrics["gate_comparisons"] = sum(room["comparisons"] for room in view)
                if timed is not None:
                    metrics.update(
                        bytes_per_room_sync_captured=timed["roomBytes"]["bytesPerRoomSync"],
                        bytes_per_room_sync_deflate=timed["roomBytes"]["deflateBytesPerRoomSync"],
                        captured_rooms=timed["roomBytes"]["rooms"],
                        decode_apply_us_per_frame=timed["summary"]["decodeApply"]["usPerFrame"],
                        decode_us_per_frame=None if timed["summary"]["decode"] is None else timed["summary"]["decode"]["usPerFrame"],
                        decode_provenance_verified=decode["provenance"]["verified"],
                    )
                out = {
                    "meta": {
                        "date": meta.get("timestampUTC", ""),
                        "git_sha": (meta.get("git") or {}).get("commit"),
                        # The wire knobs the run recorded (EncodingBenchmark metadata; None before
                        # they existed): resolved and gated with deep-research/wireform.py.
                        "path_index": meta.get("pathIndex"),
                        "field_merge": meta.get("fieldMerge"),
                        "git_dirty": (record.get("git") or {}).get("dirty"),
                        "swift_version": re.search(r"version ([\d.]+)", meta["build"]["swiftVersion"]).group(1),
                        "build_config": meta["build"]["configuration"],
                        "node_version": record.get("nodeVersion"),
                        "command": " ".join(["swift run -c release EncodingBenchmark"] + cmd[1:]),
                        "server_env": record.get("serverEnv"),
                        "source_file": str(path.relative_to(raw)),
                    },
                    "params": {
                        "axis": axis, "variant": variant, "players": players, "rooms": rooms,
                        "monster_cap": cap, "workload": "active" if active else "idle",
                        "encoding": arg(cmd, "--format"), "sync_strategy": arg(cmd, "--sync-strategy") or "delta",
                        "server_events": variant == "sst-events", "ticks_per_sync": arg(cmd, "--ticks-per-sync", int),
                        "iterations": iterations, "repeat": record["repeat"], "order": record["order"], "sweep": record["runId"],
                    },
                    "metrics": metrics,
                }
                (results / f"{run_id}.json").write_text(json.dumps(out, indent=2, sort_keys=True) + "\n", encoding="utf-8")
                written.append(run_id)
        written += collect_b1(directory, record, raw, results)
    return written


def collect_state(directory, record, raw, results):
    """One results/state/<axis>-p<P>-r<R>[-capN]-rep<n>.json per run of each <cell>-sst.state.json
    (stateshape.py: SST's sync state by the counting rule; repeat 0 for a state-only sweep)."""
    written = []
    out_dir = results / "state"
    for path in sorted(directory.glob("*.state.json")):
        stem = path.name[: -len(".state.json")]
        cell, variant = split_tag(stem)
        if variant != "sst":
            sys.exit(f"{path}: not <cell>-sst.state.json")
        axis = "rooms" if cell == "rooms" else "active" if cell.startswith("active") else "monsters"
        git = record.get("git") or {}
        for run, state in json.loads(path.read_text(encoding="utf-8")).items():
            m = re.search(r"-r(\d+)-p(\d+)-m(\d+)(-active)?-serial$", run)
            if not m:
                sys.exit(f"{path}: unexpected run {run}")
            rooms, players, active = int(m.group(1)), int(m.group(2)), bool(m.group(4))
            cap = None if axis == "rooms" else int(m.group(3))
            if state["players_per_room"] != players:
                sys.exit(f"{path}: run {run} has {state['players_per_room']} players per room in its capture")
            out = {
                "meta": {"git_sha": git.get("commit"), "git_dirty": git.get("dirty"),
                         "sources_tree": git.get("sourcesTree"), "package_tree": git.get("packageTree"),
                         "swift_version": record.get("swiftVersion"), "pin_cpus": record.get("pinCpus"),
                         "server_env": record.get("serverEnv"), "source_file": str(path.relative_to(raw))},
                "params": {"axis": axis, "players": players, "rooms": rooms, "monster_cap": cap,
                           "workload": "active" if active else "idle", "repeat": record["repeat"],
                           "state_only": bool(record.get("stateOnly")), "sweep": record["runId"]},
                "metrics": state,
            }
            run_id = (f"{axis}-p{players}-r{rooms}" + (f"-cap{cap}" if axis == "monsters" else "") + f"-rep{record['repeat']}")
            out_dir.mkdir(parents=True, exist_ok=True)
            (out_dir / f"{run_id}.json").write_text(json.dumps(out, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            written.append(f"state/{run_id}")
    return written


def projection_digest(path, key):
    hashes = json.loads(path.read_text(encoding="utf-8")).get(key)
    if hashes is None:
        sys.exit(f"{path}: no run {key}")
    return hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()


def collect_b1(directory, record, raw, results):
    """One result per converted run of each <cell>-b1*.colyseus.json (B1 has no benchmark output:
    its figures are per room over the captured rooms)."""
    written = []
    for path in sorted(directory.glob("*.colyseus.json")):
        stem = path.name[: -len(".colyseus.json")]
        cell, variant = split_tag(stem)
        if variant not in B1_VARIANTS:
            sys.exit(f"{path}: not <cell>-b1[-tuned].colyseus.json")
        report = json.loads(path.read_text(encoding="utf-8"))
        views = json.loads((directory / f"{stem}.views.json").read_text(encoding="utf-8"))
        decode = json.loads((directory / f"{stem}.decode.json").read_text(encoding="utf-8"))
        axis = "rooms" if cell == "rooms" else "active" if cell.startswith("active") else "monsters"
        for run, converted in report["runs"].items():
            m = re.search(r"-r(\d+)-p(\d+)-m(\d+)(-active)?-serial$", run)
            if not m:
                sys.exit(f"{path}: unexpected run {run}")
            rooms, players, active = int(m.group(1)), int(m.group(2)), bool(m.group(4))
            cap = None if axis == "rooms" else int(m.group(3))
            key = f"r{rooms}-p{players}-m{m.group(3)}{'-active' if active else ''}-serial"
            view, timed = views["runs"][run], decode["runs"][run]
            metrics = {
                "bytes_per_room_sync_captured": timed["roomBytes"]["bytesPerRoomSync"],
                "bytes_per_room_sync_deflate": timed["roomBytes"]["deflateBytesPerRoomSync"],
                "captured_rooms": timed["roomBytes"]["rooms"],
                "first_sync_bytes_per_room": converted["firstSyncBytes"] / converted["rooms"],
                "decode_apply_us_per_frame": timed["summary"]["decodeApply"]["usPerFrame"],
                "decode_us_per_frame": None,
                "decode_provenance_verified": decode["provenance"]["verified"],
                "encode_us_per_room_sync_node": converted["encodeUsPerRoomSyncNode"],
                "gate_passed": all(room["decodeErrors"] == 0 and not room["differences"] for room in view),
                "gate_comparisons": sum(room["comparisons"] for room in view),
                "projection_sha256": projection_digest(directory / f"{stem}.projections.json", key),
                "field_types": converted["fieldTypes"],
            }
            run_id = (f"{axis}-p{players}-r{rooms}" + (f"-cap{cap}" if axis == "monsters" else "") + f"-{variant}-rep{record['repeat']}")
            out = {
                "meta": {
                    "date": record.get("startedAt"),
                    "git_sha": (record.get("git") or {}).get("commit"),
                    "git_dirty": (record.get("git") or {}).get("dirty"),
                    "build_config": None,
                    "node_version": record.get("nodeVersion"),
                    "package": f"{report['package']}@{report['version']}",
                    "command": f"node dist/colyseus-baseline-main.js --typing {report['typing']} (from {cell}-sst's capture)",
                    "source_file": str(path.relative_to(raw)),
                },
                "params": {
                    "axis": axis, "variant": variant, "players": players, "rooms": rooms, "monster_cap": cap,
                    "workload": "active" if active else "idle", "encoding": "colyseus-schema", "typing": report["typing"],
                    "server_events": False, "repeat": record["repeat"], "order": record["order"], "sweep": record["runId"],
                },
                "metrics": metrics,
            }
            (results / f"{run_id}.json").write_text(json.dumps(out, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            written.append(run_id)
    return written


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", type=pathlib.Path, default=TOPIC / "raw")
    ap.add_argument("--results", type=pathlib.Path, default=TOPIC / "results")
    args = ap.parse_args()
    for run_id in collect(args.raw, args.results):
        print(run_id)


if __name__ == "__main__":
    main()
