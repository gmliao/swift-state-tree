#!/usr/bin/env python3
"""Convert run.sh's raw outputs into results/ (stdlib only).

- A measured invocation raw/<RUN_ID>/ (run.json kind ``measured``): each <cell>-<form>.json
  (EncodingBenchmark scalability-matrix output) becomes one results/<cell>-p<P>-<form>-rep<n>.json
  per player count in it. The repeat and its form order come from run.json only. Two invocations
  that claim the same repeat are refused unless all but one are superseded (``runmeta.py
  supersede``).
- The capture block (run.json kind ``capture``): each cell's verify-views report
  (<cell>-<form>.views.json) and frame hashes (<cell>-<form>.frames.json) become one
  results/capture/<cell>-p<P>-<form>.json per player count. One capture block, unless the others
  are superseded.

An invocation of a few cells or forms (run.sh CELLS= or FORMS=) is a smoke run and is skipped.
Every check is regenerate.py's; collect.py only converts.

Usage: python3 collect.py [--raw <dir>] [--results <dir>]
"""
import argparse, json, pathlib, re, sys

TOPIC = pathlib.Path(__file__).resolve().parent
FORMS = ("mp-dt-dk", "mp-dt-nodk", "mp-nodt-dk", "mp-nodt-nodk", "oj-dk", "oj-nodk")
CELLS = ("monsters-cap4", "monsters-cap10", "monsters-cap50", "monsters-cap100", "idle-players", "active-players", "joint")


def invocations(raw):
    """(measured: {repeat: (path, record)}, capture: (path, record) or None), smoke runs skipped."""
    measured, captures = {}, []
    for record_path in sorted(raw.glob("*/run.json")):
        record = json.loads(record_path.read_text(encoding="utf-8"))
        if record.get("superseded"):
            continue
        if record.get("onlyCells") or record.get("onlyForms"):
            print(f"skipping {record_path.parent.name}: a smoke run (only {record.get('onlyCells') or ''} {record.get('onlyForms') or ''})",
                  file=sys.stderr)
            continue
        if record["kind"] == "capture":
            captures.append((record_path, record))
            continue
        if record["repeat"] in measured:
            sys.exit(f"repeat {record['repeat']} is claimed by both {measured[record['repeat']][0].parent.name} "
                     f"and {record_path.parent.name}; mark one superseded (runmeta.py supersede)")
        measured[record["repeat"]] = (record_path, record)
    if len(captures) > 1:
        sys.exit(f"{len(captures)} capture blocks ({', '.join(c[0].parent.name for c in captures)}); mark all but one superseded")
    return measured, (captures[0] if captures else None)


def split_tag(stem):
    for form in sorted(FORMS, key=len, reverse=True):
        if stem.endswith("-" + form) and stem[: -len(form) - 1] in CELLS:
            return stem[: -len(form) - 1], form
    return None, None


def arg(cmd, flag, cast=str):
    return cast(cmd[cmd.index(flag) + 1]) if flag in cmd else None


def run_meta(record):
    git = record.get("git") or {}
    return {
        "git_sha": git.get("commit"), "git_dirty": git.get("dirty"),
        "sources_tree": git.get("sourcesTree"), "package_tree": git.get("packageTree"),
        "swift_version": record.get("swiftVersion"), "node_version": record.get("nodeVersion"),
        "server_env": record.get("serverEnv"), "pin_cpus": record.get("pinCpus"),
    }


def label_suffix(rooms, players, cap, active):
    return f"-r{rooms}-p{players}-m{cap or 0}{'-active' if active else ''}-serial"


def by_suffix(entries, suffix, what):
    hits = [v for k, v in entries.items() if k.endswith(suffix)]
    if len(hits) != 1:
        sys.exit(f"expected one {what} ending {suffix}, found {len(hits)}")
    return hits[0]


def collect_measured(directory, record, results):
    written = []
    for path in sorted(directory.glob("*.json")):
        if path.name == "run.json":
            continue
        cell, form = split_tag(path.stem)
        if form is None:
            sys.exit(f"{path}: not <cell>-<form>.json")
        d = json.loads(path.read_text(encoding="utf-8"))
        meta, cmd = d["metadata"], d["metadata"]["commandLine"]
        cap, active = arg(cmd, "--monster-cap", int), "--active-players" in cmd
        iterations, tps = arg(cmd, "--iterations", int), arg(cmd, "--ticks-per-sync", int)
        for r in d["results"]:
            rooms, players, half = r["rooms"], r["playersPerRoom"], r["serial"]
            swift = re.search(r"version ([\d.]+)", meta["build"].get("swiftVersion") or "")
            out = {
                "meta": {**run_meta(record),
                         "date": meta.get("timestampUTC", ""),
                         "bench_git_sha": (meta.get("git") or {}).get("commit"),
                         "dirty_tracking": meta.get("dirtyTracking"),
                         "dynamic_key_compression": meta.get("dynamicKeyCompression"),
                         "path_index": meta.get("pathIndex"), "field_merge": meta.get("fieldMerge"),
                         "build_config": meta["build"]["configuration"],
                         "bench_swift_version": swift.group(1) if swift else None,
                         "command": " ".join(["swift run -c release EncodingBenchmark"] + cmd[1:]),
                         "source_file": f"{directory.name}/{path.name}"},
                "params": {"cell": cell, "form": form, "players": players, "monster_cap": cap,
                           "workload": "active" if active else "idle", "rooms": rooms, "encoding": arg(cmd, "--format"),
                           "sync_strategy": arg(cmd, "--sync-strategy") or "delta",
                           "parallel": arg(cmd, "--parallel"), "ticks_per_sync": tps, "iterations": iterations,
                           "repeat": record["repeat"], "order": record["order"], "sweep": record["runId"]},
                "metrics": {
                    "total_bytes": half["totalBytes"],
                    "bytes_per_sync": half["totalBytes"] / iterations,
                    "bytes_per_player_per_sync": half["totalBytes"] / iterations / players,
                    "sync_ms_per_sync": half["syncMs"] / iterations if half.get("syncMs") is not None else None,
                    "iteration_cpu_ms": half["cpuMs"] / iterations if half.get("cpuMs") is not None else None,
                    "final_monster_count": half.get("finalMonsterCount"),
                },
            }
            name = f"{cell}-p{players}-{form}-rep{record['repeat']}"
            (results / f"{name}.json").write_text(json.dumps(out, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            written.append(name)
    return written


def collect_capture(directory, record, results):
    out_dir = results / "capture"
    out_dir.mkdir(parents=True, exist_ok=True)
    written = []
    for views_path in sorted(directory.glob("*.views.json")):
        stem = views_path.name[: -len(".views.json")]
        cell, form = split_tag(stem)
        if form is None:
            sys.exit(f"{views_path}: not <cell>-<form>.views.json")
        frames_path = directory / f"{stem}.frames.json"
        if not frames_path.exists():
            sys.exit(f"{frames_path}: missing (the capture pass's frame hashes)")
        report, frames = json.loads(views_path.read_text(encoding="utf-8")), json.loads(frames_path.read_text(encoding="utf-8"))
        for label in sorted(frames):
            m = re.search(r"-r(\d+)-p(\d+)-m(\d+)(-active)?-serial$", label)
            if not m:
                sys.exit(f"{frames_path}: run label {label!r} isn't a hero-defense serial run")
            rooms, players, cap, active = int(m.group(1)), int(m.group(2)), int(m.group(3)), bool(m.group(4))
            suffix = label_suffix(rooms, players, cap, active)
            view = by_suffix(report["runs"], suffix, "verify-views run")
            out = {
                "meta": {**run_meta(record), "deterministic_hashing": record.get("deterministicHashing"),
                         "source_file": f"{directory.name}/{stem}"},
                "params": {"cell": cell, "form": form, "players": players, "monster_cap": cap,
                           "workload": "active" if active else "idle", "rooms": rooms, "sweep": record["runId"]},
                "metrics": {
                    # A room passes when every recipient decoded every frame and matched after every sync.
                    "gate_passed": all(room["decodeErrors"] == 0 and not room["differences"] for room in view),
                    "gate_comparisons": sum(room["comparisons"] for room in view),
                    "frames_sha256": frames[label]["sha256"],
                    "frames": frames[label]["frames"],
                    "syncs": frames[label]["syncs"],
                },
            }
            name = f"{cell}-p{players}-{form}"
            (out_dir / f"{name}.json").write_text(json.dumps(out, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            written.append(f"capture/{name}")
    return written


def collect(raw, results):
    results.mkdir(parents=True, exist_ok=True)
    measured, capture = invocations(raw)
    written = []
    for _, (record_path, record) in sorted(measured.items()):
        written += collect_measured(record_path.parent, record, results)
    if capture:
        written += collect_capture(capture[0].parent, capture[1], results)
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
