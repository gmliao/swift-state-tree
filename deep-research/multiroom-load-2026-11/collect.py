#!/usr/bin/env python3
"""Convert run.sh's sweeps (raw/<RUN_ID>/) into results/<RUN_ID>/, which regenerate.py --sweep reads
(stdlib only). The published 2026-11-06 set under data/ is not touched.

For every sweep raw/<RUN_ID>/ with a run.json that isn't superseded, results/<RUN_ID>/ gets:
  sweep.json            the sweep's record (run.json: commit, dirty tree, Swift and Node versions,
                        build configuration, pinning, smoke overrides, end time) and, per run, its
                        last status, exit code, command, shims, the server's CPU list seen during the
                        run, and its toolchain.txt (Swift, Node, GameServer binary and source commit);
  <run>/report.json.gz  the ws-loadtest report (gzip of run-1/ws-loadtest-*.json, as under data/rerun/);
  <run>/summary.json, <run>/toolchain.txt  the scalability script's summary and the run's toolchains.

Smoke sweeps and sweeps that didn't finish are converted too, so that regenerate.py refuses them
by name rather than never seeing them. Every check is regenerate.py's; collect.py only refuses
an output layout it can't read (two scalability directories in one run, two reports).

Usage: python3 collect.py [--raw <dir>] [--results <dir>] [--run-id <RUN_ID>]

--run-id converts that sweep only: results/ holds the arm sweeps and the control that
regenerate.py tables (a smoke sweep beside them would make README regeneration refuse them all).
Each run also gets its load client's own load per phase (clientLoad, clientload.py).
"""
import argparse, gzip, json, pathlib, re, shutil, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import landstats  # noqa: E402
import portable  # noqa: E402

TOPIC = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOPIC))
import clientload  # noqa: E402


def last_status(record, name):
    statuses = [c["status"] for c in record.get("cells") or [] if c.get("tag") == name]
    return statuses[-1] if statuses else None


def parse_header(path):
    """The run header run.sh writes: key=value lines, `cmd:`, `shim <name>:` and the server's CPUs."""
    out = {"exit": None, "cmd": None, "shims": {}, "serverAffinity": None, "sha": None, "sendBacklogEnv": None}
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        if line.startswith("exit="):
            out["exit"] = int(line.split()[0].split("=", 1)[1])
        elif line.startswith("sha="):
            out["sha"] = line.split("=", 1)[1]
        elif line.startswith("cmd: "):
            out["cmd"] = line[len("cmd: "):]
        elif line.startswith("shim "):
            name, _, body = line[len("shim "):].partition(": ")
            out["shims"][name] = body
        elif line.startswith("WS_SEND_BACKLOG_* env: "):
            values = re.findall(r"\[([^\]]*)\]", line)
            if len(values) == 2:
                out["sendBacklogEnv"] = {"WS_SEND_BACKLOG_MAX_BYTES": None if values[0] == "unset" else values[0],
                                         "WS_SEND_BACKLOG_MAX_UNWRITABLE_MS": None if values[1] == "unset" else values[1]}
        elif line.startswith("server Cpus_allowed_list: "):
            value = line.split(": ", 1)[1].strip()
            out["serverAffinity"] = None if value.startswith("<") else value
    return out


def parse_toolchain(path):
    out = {"swift": None, "node": None, "gameserverBin": None, "sourceSha": None}
    if path is None or not path.exists():
        return out
    for line in path.read_text().splitlines():
        if line.startswith("Swift version") and out["swift"] is None:
            out["swift"] = line.strip()
        elif line.startswith("node "):
            out["node"] = line.split(" ", 1)[1].strip()
        elif line.startswith("GAMESERVER_BIN="):
            out["gameserverBin"] = line.split("=", 1)[1]
        elif line.startswith("GAMESERVER_SOURCE_SHA="):
            out["sourceSha"] = line.split("=", 1)[1]
    return out


def join_features(report):
    """The joins per wire form over the report's phases (`phaseTotals.stateUpdateFeatures`, keyed
    `<encoding>:<features>`, which wireform.join_form reads); None when no phase records them (an
    older client), a missing input at a commit that has the knobs.

    "<encoding>:none" is both features off, even though the join's response had no field at all:
    the server never sends an empty list (TransportAdapter's joinResponse sets
    `stateUpdateFeatures` to nil when no feature is on, and the opcode encoders drop trailing nils)."""
    merged, seen = {}, False
    for phase in report.get("phases") or []:
        counts = (phase.get("phaseTotals") or {}).get("stateUpdateFeatures")
        if counts is None:
            continue
        seen = True
        for key, n in counts.items():
            merged[key] = merged.get(key, 0) + n
    return merged if seen else None


def one(paths, what):
    paths = sorted(paths)
    if len(paths) > 1:
        sys.exit(f"expected one {what}, found {len(paths)}: {', '.join(str(p) for p in paths)}")
    return paths[0] if paths else None


def steady_land_stats(path, report):
    """landstats.summary over the steady phase's measured window (its origin plus its warm-up,
    for its measured length, as the report records them), or None without the stats file or a
    steady measurement."""
    if report is None or not path.exists():
        return None
    steady = next((p for p in report.get("phases") or [] if p.get("name") == "steady"), None)
    m = (steady or {}).get("measurement") or {}
    if not all(isinstance(m.get(k), (int, float)) for k in ("originAt", "warmupMs", "measuredMs")):
        return None
    start = int(m["originAt"] + m["warmupMs"])
    return landstats.summary(landstats.read(path), start, start + int(m["measuredMs"]))


def collect_sweep(directory, results, checkout_root=None):
    record = json.loads((directory / "run.json").read_text())
    dirty = (record.get("git") or {}).get("dirty")
    if not isinstance(dirty, bool):
        sys.exit(f"{directory}/run.json: no git.dirty recorded (got {dirty!r}); run the sweep with this topic's run.sh, whose runmeta.py records git.dirty in run.json")
    # The checkout the sweep ran in (run.json git.root, else --checkout-root): the paths its
    # run-time files recorded under it are kept relative to it (portable.py); any other stays.
    root = portable.checkout_root(record, checkout_root, f"{directory}/run.json")
    out = results / directory.name
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    runs = {}
    names = sorted({p.name for p in directory.iterdir() if p.is_dir() and p.name != "shim"}
                   | {c["tag"] for c in record.get("cells") or []})
    for name in names:
        run_dir = directory / name
        header = parse_header(directory / f"{name}.run-header.txt")
        suite = one(run_dir.glob("scalability-*"), f"scalability directory in {run_dir}") if run_dir.is_dir() else None
        report = one(suite.glob("run-1/ws-loadtest-*.json"), f"report in {suite}/run-1") if suite else None
        toolchain = parse_toolchain(suite / "run-1" / "toolchain.txt" if suite else None)
        target = out / name
        target.mkdir()
        report_data = json.loads(report.read_text()) if report else None
        features = join_features(report_data) if report else None
        if report:
            # mtime=0: the same report gives the same bytes.
            with open(target / "report.json.gz", "wb") as raw_file, \
                    gzip.GzipFile(filename="", mode="wb", fileobj=raw_file, mtime=0) as f:
                # Paths the client recorded, relative to the checkout (portable.py), like every file here.
                f.write(portable.checkout_relative(report.read_bytes().decode("utf-8"), root).encode("utf-8"))
        for f in ("summary.json", "run-1/toolchain.txt"):
            if suite and (suite / f).exists():
                (target / pathlib.Path(f).name).write_text(portable.checkout_relative((suite / f).read_text(encoding="utf-8"), root), encoding="utf-8")
        runs[name] = {
            "status": last_status(record, name),
            "exit": header["exit"],
            "cmd": header["cmd"],
            "profiled": header["cmd"] is not None and "--profile" in header["cmd"].split(),
            "shims": header["shims"],
            "serverAffinity": header["serverAffinity"],
            "headerSha": header["sha"],
            "toolchain": toolchain,
            "sendBacklogEnv": header["sendBacklogEnv"],
            "stateUpdateFeatures": features,
            "report": report is not None,
            # The steady window's monster load (landstats.py), from the run's own server stats:
            # None without the file or without a steady measurement in the report.
            "steadyLandStats": steady_land_stats(run_dir / "land-stats.jsonl", report_data),
            # The load client's own load per phase (clientload.py), over the client's pinned CPUs.
            "clientLoad": clientload.measure(report_data, clientload.client_mask(record.get("pinCpus"))) if report_data else None,
        }
    sweep = {k: record.get(k) for k in ("runId", "git", "swiftVersion", "nodeVersion", "buildConfig", "pinCpus",
                                        "overrides", "timeWait", "startedAt", "endedAt", "superseded",
                                        "wire", "sendBacklogEnv", "spawnRampTicks", "spawnRampTicksEffective",
                                        "steadyWarmupS", "moveToPerS", "control", "topRooms", "suiteRooms")}
    # The checkout root itself is a host path; the record keeps it, the result doesn't.
    sweep["git"] = {k: v for k, v in (sweep["git"] or {}).items() if k != "root"} if sweep["git"] is not None else None
    sweep["onlyRuns"] = record.get("onlyCells")
    sweep["runs"] = runs
    # run.sh records the GameServer binary by its path in the checkout (GAMESERVER_BIN, toolchain.txt).
    sweep = portable.relativize(sweep, root)
    (out / "sweep.json").write_text(json.dumps(sweep, indent=2, sort_keys=True) + "\n")
    return out


def collect(raw, results, run_id=None, checkout_root=None):
    written = []
    for run_json in sorted(raw.glob("*/run.json")):
        if run_id is not None and run_json.parent.name != run_id:
            continue
        record = json.loads(run_json.read_text())
        if record.get("superseded"):
            print(f"skipping {run_json.parent.name}: superseded ({record['superseded'].get('reason')})", file=sys.stderr)
            continue
        written.append(collect_sweep(run_json.parent, results, checkout_root))
    return written


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", type=pathlib.Path, default=TOPIC / "raw")
    ap.add_argument("--results", type=pathlib.Path, default=TOPIC / "results")
    ap.add_argument("--run-id")
    ap.add_argument("--checkout-root", help="the checkout the sweep ran in, for a run.json that doesn't record it (git.root)")
    args = ap.parse_args()
    written = collect(args.raw, args.results, args.run_id, args.checkout_root)
    if args.run_id is not None and not written:
        sys.exit(f"no sweep raw/{args.run_id}/run.json (or it is superseded)")
    for out in written:
        print(out)


if __name__ == "__main__":
    main()
