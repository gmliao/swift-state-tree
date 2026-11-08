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

Usage: python3 collect.py [--raw <dir>] [--results <dir>]
"""
import argparse, gzip, json, pathlib, shutil, sys

TOPIC = pathlib.Path(__file__).resolve().parent


def last_status(record, name):
    statuses = [c["status"] for c in record.get("cells") or [] if c.get("tag") == name]
    return statuses[-1] if statuses else None


def parse_header(path):
    """The run header run.sh writes: key=value lines, `cmd:`, `shim <name>:` and the server's CPUs."""
    out = {"exit": None, "cmd": None, "shims": {}, "serverAffinity": None, "sha": None}
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


def one(paths, what):
    paths = sorted(paths)
    if len(paths) > 1:
        sys.exit(f"expected one {what}, found {len(paths)}: {', '.join(str(p) for p in paths)}")
    return paths[0] if paths else None


def collect_sweep(directory, results):
    record = json.loads((directory / "run.json").read_text())
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
        if report:
            # mtime=0: the same report gives the same bytes.
            with open(target / "report.json.gz", "wb") as raw_file, \
                    gzip.GzipFile(filename="", mode="wb", fileobj=raw_file, mtime=0) as f:
                f.write(report.read_bytes())
        for f in ("summary.json", "run-1/toolchain.txt"):
            if suite and (suite / f).exists():
                shutil.copy(suite / f, target / pathlib.Path(f).name)
        runs[name] = {
            "status": last_status(record, name),
            "exit": header["exit"],
            "cmd": header["cmd"],
            "profiled": header["cmd"] is not None and "--profile" in header["cmd"].split(),
            "shims": header["shims"],
            "serverAffinity": header["serverAffinity"],
            "headerSha": header["sha"],
            "toolchain": toolchain,
            "report": report is not None,
        }
    sweep = {k: record.get(k) for k in ("runId", "git", "swiftVersion", "nodeVersion", "buildConfig", "pinCpus",
                                        "overrides", "timeWait", "startedAt", "endedAt", "superseded")}
    sweep["onlyRuns"] = record.get("onlyCells")
    sweep["runs"] = runs
    (out / "sweep.json").write_text(json.dumps(sweep, indent=2, sort_keys=True) + "\n")
    return out


def collect(raw, results):
    written = []
    for run_json in sorted(raw.glob("*/run.json")):
        record = json.loads(run_json.read_text())
        if record.get("superseded"):
            print(f"skipping {run_json.parent.name}: superseded ({record['superseded'].get('reason')})", file=sys.stderr)
            continue
        written.append(collect_sweep(run_json.parent, results))
    return written


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", type=pathlib.Path, default=TOPIC / "raw")
    ap.add_argument("--results", type=pathlib.Path, default=TOPIC / "results")
    args = ap.parse_args()
    for out in collect(args.raw, args.results):
        print(out)


if __name__ == "__main__":
    main()
