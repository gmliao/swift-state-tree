#!/usr/bin/env python3
"""Convert run.sh's raw outputs into one results/<run-id>.json per (cell, variant, repeat),
following the experiment-artifacts contract (stdlib only).

For every sweep raw/<RUN_ID>/ whose run.json isn't superseded, each <cell>-<variant>.json
(EncodingBenchmark scalability-matrix output) becomes one result, with that variant's capture
reports joined in (<tag>.views.json, .decode.json, .capstats.json, .replay.json) and the cell's
<cell>.consistency.json. The land's settings come from the result's own metadata
(`benchmarkConfig.visibility`), which the benchmark writes from the settings it ran with. The
repeat and order come from run.json only. Two sweeps that claim the same repeat are refused
unless all but one are superseded; a sweep of a few cells (CELLS=...) is skipped.

Usage: python3 collect.py [--raw <dir>] [--results <dir>]
"""
import argparse, json, pathlib, re, sys

TOPIC = pathlib.Path(__file__).resolve().parent
VARIANTS = ("radius", "all")
SETTINGS = {"VISIBILITY_TEST_ENTITY_COUNT": "entity_count", "VISIBILITY_TEST_VIEW_RADIUS": "view_radius",
            "VISIBILITY_TEST_FILTER": "filter"}


def sweeps(raw):
    claimed = {}
    for record_path in sorted(raw.glob("*/run.json")):
        record = json.loads(record_path.read_text())
        if record.get("superseded"):
            continue
        if record["repeat"] in claimed:
            sys.exit(f"repeat {record['repeat']} is claimed by both {claimed[record['repeat']][0].parent.name} "
                     f"and {record_path.parent.name}; mark one superseded (runmeta.py supersede)")
        claimed[record["repeat"]] = (record_path, record)
    return sorted(claimed.values(), key=lambda s: s[1]["repeat"])


def arg(cmd, flag, cast=str):
    return cast(cmd[cmd.index(flag) + 1]) if flag in cmd else None


def only_run(report, path, key):
    """The one run of a capture report keyed by its cell suffix (`r<rooms>-p<players>-k<tps>-serial`)."""
    hits = [v for k, v in report.items() if k == key or k.endswith(f"-visibility-test-{key}")]
    if len(hits) != 1:
        sys.exit(f"{path}: expected one run {key}, found {len(hits)}")
    return hits[0]


def read(path):
    return json.loads(path.read_text()) if path.exists() else None


def collect(raw, results):
    results.mkdir(parents=True, exist_ok=True)
    written = []
    for record_path, record in sweeps(raw):
        directory = record_path.parent
        if record.get("onlyCells"):
            print(f"skipping {directory.name}: only cells {record['onlyCells']}", file=sys.stderr)
            continue
        for path in sorted(directory.glob("*.json")):
            if path.name == "run.json" or re.search(r"\.(views|decode|capstats|replay|consistency)\.json$", path.name):
                continue
            match = re.fullmatch(r"(.+)-(radius|all)", path.stem)
            if not match:
                sys.exit(f"{path}: not <cell>-<variant>.json")
            cell, variant = match.groups()
            d = json.loads(path.read_text())
            meta, cmd = d["metadata"], d["metadata"]["commandLine"]
            config = meta["benchmarkConfig"]
            settings = config.get("visibility")
            if config.get("gameType") != "visibility-test" or settings is None:
                sys.exit(f"{path}: not a visibility-test run with its settings recorded")
            if settings["VISIBILITY_TEST_FILTER"] != variant:
                sys.exit(f"{path}: ran with filter {settings['VISIBILITY_TEST_FILTER']}, not {variant}")
            if len(d["results"]) != 1:
                sys.exit(f"{path}: expected one result, found {len(d['results'])}")
            r = d["results"][0]
            rooms, players, half = r["rooms"], r["playersPerRoom"], r["serial"]
            iterations, tps = config["iterations"], config["ticksPerSync"]
            metrics = {
                "bytes_per_recipient_sync": half["totalBytes"] / (iterations * rooms * players),
                "sync_us_per_room_sync": half["syncMs"] * 1000 / (rooms * iterations),
                "tick_us_per_room_tick": half["tickMs"] * 1000 / (rooms * iterations * tps),
            }
            key = f"r{rooms}-p{players}-k{tps}-serial"
            views, decode = read(directory / f"{path.stem}.views.json"), read(directory / f"{path.stem}.decode.json")
            capstats, replay = read(directory / f"{path.stem}.capstats.json"), read(directory / f"{path.stem}.replay.json")
            consistency = read(directory / f"{cell}.consistency.json")
            if views is not None:
                view = only_run(views["runs"], path, key)
                # A room passes when every recipient decoded every frame and matched after every sync.
                metrics["gate_passed"] = all(room["decodeErrors"] == 0 and not room["differences"] for room in view)
                metrics["gate_comparisons"] = sum(room["comparisons"] for room in view)
            if decode is not None:
                timed = only_run(decode["runs"], path, key)
                metrics.update(
                    bytes_per_recipient_sync_captured=timed["roomBytes"]["bytesPerRoomSync"] / players,
                    bytes_per_recipient_sync_deflate=timed["roomBytes"]["deflateBytesPerRoomSync"] / players,
                    captured_rooms=timed["roomBytes"]["rooms"],
                    decode_apply_us_per_frame=timed["summary"]["decodeApply"]["usPerFrame"],
                    decode_us_per_frame=None if timed["summary"]["decode"] is None else timed["summary"]["decode"]["usPerFrame"],
                    decode_provenance_verified=decode["provenance"]["verified"],
                )
            if capstats is not None:
                stats = only_run(capstats, path, key)
                metrics.update(visible_per_recipient=stats["visiblePerRecipient"],
                               view_changes_per_recipient_sync=stats["viewChangesPerRecipientSync"])
            if replay is not None:
                verdicts = only_run(replay, path, key)
                metrics.update(replay_passed=all(v["passed"] for v in verdicts.values()), replay_rooms=len(verdicts))
            if consistency is not None:
                checked = only_run(consistency, path, key)
                metrics.update(consistency_passed=checked["failure"] is None, consistency_checks=checked["checks"])
            run_id = f"{cell}-{variant}-rep{record['repeat']}"
            out = {
                "meta": {
                    "date": meta.get("timestampUTC", ""),
                    "git_sha": (meta.get("git") or {}).get("commit"),
                    "git_dirty": (record.get("git") or {}).get("dirty"),
                    "swift_version": re.search(r"version ([\d.]+)", meta["build"]["swiftVersion"]).group(1),
                    "build_config": meta["build"]["configuration"],
                    "node_version": record.get("nodeVersion"),
                    "command": " ".join([f"{k}={settings[k]}" for k in sorted(settings)] + ["USE_SNAPSHOT_FOR_SYNC=false",
                                         "swift run -c release EncodingBenchmark"] + cmd[1:]),
                    "source_file": str(path.relative_to(raw)),
                },
                "params": {
                    "cell": cell, "variant": variant,
                    "entity_count": int(settings["VISIBILITY_TEST_ENTITY_COUNT"]),
                    "view_radius": float(settings["VISIBILITY_TEST_VIEW_RADIUS"]),
                    "players": players, "rooms": rooms, "ticks_per_sync": tps, "iterations": iterations,
                    "encoding": arg(cmd, "--format"), "sync_strategy": arg(cmd, "--sync-strategy") or "delta",
                    "server_events": "--no-server-events" not in cmd, "parallel": arg(cmd, "--parallel"),
                    "repeat": record["repeat"], "order": record["order"], "sweep": record["runId"],
                },
                "metrics": metrics,
            }
            (results / f"{run_id}.json").write_text(json.dumps(out, indent=2, sort_keys=True) + "\n")
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
