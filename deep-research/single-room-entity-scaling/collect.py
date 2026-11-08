#!/usr/bin/env python3
"""Convert run.sh's raw outputs into one results/<run-id>.json per (point, form, repeat), following
the experiment-artifacts contract (stdlib only).

For every sweep raw/<RUN_ID>/ whose run.json isn't superseded and isn't a smoke (CELLS or FORMS),
each <cell>-<form>.json (EncodingBenchmark scalability-matrix output) becomes one result per
player count in it, with its verify-views report (<cell>-<form>.views.json, the gate) joined in.
The repeat comes from run.json only. Two sweeps that claim the same repeat are refused unless all
but one are superseded.

Usage: python3 collect.py [--raw <dir>] [--results <dir>]
"""
import argparse, json, pathlib, re, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import portable  # noqa: E402

TOPIC = pathlib.Path(__file__).resolve().parent
FORMS = ("json", "on-on", "on-off", "off-on", "off-off")
CELLS = ("monsters-cap4", "monsters-cap10", "monsters-cap50", "monsters-cap100", "idle-players", "active-players", "joint")


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


def split_tag(stem):
    for form in sorted(FORMS, key=len, reverse=True):
        if stem.endswith("-" + form) and stem[: -len(form) - 1] in CELLS:
            return stem[: -len(form) - 1], form
    return None, None


def arg(cmd, flag, cast=str):
    return cast(cmd[cmd.index(flag) + 1]) if flag in cmd else None


def capture_run(report, rooms, players, cap, active):
    """The verify-views run that holds this point."""
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
            # A smoke sweep (run.sh CELLS= or FORMS=) isn't a repeat of the matrix.
            print(f"skipping {directory.name}: only {record['onlyCells']}", file=sys.stderr)
            continue
        for path in sorted(directory.glob("*.json")):
            if path.name == "run.json" or path.name.endswith(".views.json"):
                continue
            cell, form = split_tag(path.stem)
            if form is None:
                sys.exit(f"{path}: not <cell>-<form>.json")
            d = json.loads(path.read_text())
            meta, cmd = d["metadata"], d["metadata"]["commandLine"]
            views_path = directory / f"{path.stem}.views.json"
            views = json.loads(views_path.read_text()) if views_path.exists() else None
            cap, active = arg(cmd, "--monster-cap", int), "--active-players" in cmd
            iterations, tps = arg(cmd, "--iterations", int), arg(cmd, "--ticks-per-sync", int)
            for r in d["results"]:
                rooms, players, half = r["rooms"], r["playersPerRoom"], r["serial"]
                metrics = {
                    # The benchmark's bytesPerSync is an integer division; totalBytes / iterations
                    # is the same figure unrounded.
                    "total_bytes": half["totalBytes"],
                    "bytes_per_sync": half["totalBytes"] / iterations,
                    "bytes_per_player_per_sync": half["totalBytes"] / iterations / players,
                    "final_monster_count": half.get("finalMonsterCount"),
                }
                view = capture_run(views, rooms, players, cap, active)
                if view is not None:
                    # A room passes when every recipient decoded every frame and matched after every sync.
                    metrics["gate_passed"] = all(room["decodeErrors"] == 0 and not room["differences"] for room in view)
                    metrics["gate_comparisons"] = sum(room["comparisons"] for room in view)
                run_id = f"{cell}-p{players}-{form}-rep{record['repeat']}"
                out = {
                    "meta": {
                        "date": meta.get("timestampUTC", ""),
                        "git_sha": (meta.get("git") or {}).get("commit"),
                        # The wire knobs the run recorded: resolved and gated with deep-research/wireform.py.
                        "path_index": meta.get("pathIndex"),
                        "field_merge": meta.get("fieldMerge"),
                        "dynamic_key_compression": meta.get("dynamicKeyCompression"),
                        "dirty_tracking": meta.get("dirtyTracking"),
                        "git_dirty": (record.get("git") or {}).get("dirty"),
                        "swift_version": re.search(r"version ([\d.]+)", meta["build"]["swiftVersion"] or "").group(1)
                        if re.search(r"version ([\d.]+)", meta["build"]["swiftVersion"] or "") else None,
                        "build_config": meta["build"]["configuration"],
                        "server_env": record.get("serverEnv"),
                        "pin_cpus": record.get("pinCpus"),
                        "command": " ".join(["swift run -c release EncodingBenchmark"] + cmd[1:]),
                        "source_file": str(path.relative_to(raw)),
                    },
                    "params": {
                        "cell": cell, "form": form, "players": players, "monster_cap": cap,
                        "workload": "active" if active else "idle", "rooms": rooms, "encoding": arg(cmd, "--format"),
                        # The benchmark's default strategy is delta; run.sh passes none.
                        "sync_strategy": arg(cmd, "--sync-strategy") or "delta",
                        "parallel": {"serial": False, "parallel": True}.get((r.get("config") or {}).get("mode")),
                        "ticks_per_sync": tps, "iterations": iterations,
                        "repeat": record["repeat"], "sweep": record["runId"], "captured": views is not None,
                    },
                    "metrics": metrics,
                }
                (results / f"{run_id}.json").write_text(json.dumps(portable.relativize(out), indent=2, sort_keys=True) + "\n")
                written.append(run_id)
    return written


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", type=pathlib.Path, default=TOPIC / "raw")
    ap.add_argument("--results", type=pathlib.Path, default=TOPIC / "results")
    a = ap.parse_args()
    for name in collect(a.raw, a.results):
        print(name)


if __name__ == "__main__":
    main()
