#!/usr/bin/env python3
"""Collect the input-to-visible set (MoveTo 1/s and 2/s at 100-1000 rooms) into data/input-latency/.

  python3 -I collect_input_latency.py <raw dir> [<out dir>]

<raw dir> is the set's raw directory, one entry per run, named `lat-s<suite>-m<rate>-<rooms>` (the
matrix) or `smoke-m<rate>-<rooms>` (the smoke):
  <run>/scalability-*/summary.json and <run>/scalability-*/run-1/{ws-loadtest-*.json,toolchain.txt}
  <run>.run-header.txt   the driver's header: start, exit and end, the server's spawnRampTicks and
                         Cpus_allowed_list, the client-load check's exit code, Swift, Node, kernel
  chain.log              the driver's log: TIME_WAIT at each run's start, the build's porcelain
<out dir> defaults to data/input-latency next to this script.

Writes <run>/report.json.gz (the report, gzip with no name or time in its header, so a rerun writes
the same bytes) and runs.json: per run the header's and summary's facts and the sha256 of the
uncompressed report. The summaries themselves aren't copied: regenerate.py reads only the reports
and runs.json. It refuses a run directory without exactly one report and one summary.
"""
import gzip
import hashlib
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
RUN_NAME = re.compile(r"^(?:lat-s(?P<suite>\d+)|smoke)-m(?P<rate>\d+)-(?P<rooms>\d+)$")
HEADER = {
    "start": re.compile(r"^start=(\S+)$", re.M),
    "exit": re.compile(r"^exit=(\d+) end=\S+$", re.M),
    "end": re.compile(r"^exit=\d+ end=(\S+)$", re.M),
    "spawnRampTicks": re.compile(r"^server spawnRampTicks: (\d+)$", re.M),
    "serverCpusAllowed": re.compile(r"^server Cpus_allowed_list: (\S+)$", re.M),
    "clientLoadRc": re.compile(r"^client load check rc=(\d+)$", re.M),
    "swift": re.compile(r"^swift: (.+)$", re.M),
    "node": re.compile(r"^node: (\S+)$", re.M),
    "kernel": re.compile(r"^uname -r: (\S+)$", re.M),
    "stdbufShim": re.compile(r"^shim stdbuf: (.+)$", re.M),
    "nodeShim": re.compile(r"^shim node: (.+)$", re.M),
}
INTS = ("exit", "spawnRampTicks", "clientLoadRc")


def one(paths, what, run):
    if len(paths) != 1:
        sys.exit(f"{run}: {len(paths)} {what}, expected 1")
    return paths[0]


def header_facts(text, run):
    facts = {}
    for key, pattern in HEADER.items():
        found = pattern.findall(text)
        if len(found) != 1:
            sys.exit(f"{run}.run-header.txt: {len(found)} '{key}' lines, expected 1")
        facts[key] = int(found[0]) if key in INTS else found[0].strip()
    return facts


def main(argv):
    if len(argv) not in (1, 2):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    raw = pathlib.Path(argv[0])
    out = pathlib.Path(argv[1]) if len(argv) == 2 else HERE / "data" / "input-latency"
    chain = (raw / "chain.log").read_text(encoding="utf-8")
    porcelain = [int(n) for n in re.findall(r"build: porcelain (?:before|after) (\d+)", chain)]
    runs = []
    for d in sorted(p for p in raw.iterdir() if p.is_dir() and RUN_NAME.match(p.name)):
        name, m = d.name, RUN_NAME.match(d.name)
        report_path = one(sorted(d.glob("scalability-*/run-1/ws-loadtest-*.json")), "reports", name)
        summary = json.loads(one(sorted(d.glob("scalability-*/summary.json")), "summaries", name).read_text(encoding="utf-8"))
        toolchain = (report_path.parent / "toolchain.txt").read_text(encoding="utf-8")
        source = re.findall(r"^GAMESERVER_SOURCE_SHA=([0-9a-f]{40})$", toolchain, re.M)
        start = re.findall(rf"^\S+ {re.escape(name)} start: TIME_WAIT=(\d+) waited=(\d+)s$", chain, re.M)
        if len(source) != 1 or len(start) != 1:
            sys.exit(f"{name}: {len(source)} source commits in toolchain.txt, {len(start)} start lines in chain.log")
        data = report_path.read_bytes()
        (out / name).mkdir(parents=True, exist_ok=True)
        with open(out / name / "report.json.gz", "wb") as f, gzip.GzipFile(filename="", mode="wb", fileobj=f, mtime=0) as z:
            z.write(data)
        runs.append({
            "name": name,
            "suite": int(m["suite"]) if m["suite"] else "smoke",
            "moveToPerS": int(m["rate"]),
            "rooms": int(m["rooms"]),
            "report": f"{name}/report.json.gz",
            "reportSha256": hashlib.sha256(data).hexdigest(),
            "summaryRoomCounts": (summary.get("config") or {}).get("roomCounts"),
            "summaryExitCodes": [r.get("exitCode") for r in summary.get("runs") or []],
            "sourceSha": source[0],
            "timeWaitAtStart": int(start[0][0]),
            "timeWaitWaitedS": int(start[0][1]),
            **header_facts((raw / f"{name}.run-header.txt").read_text(encoding="utf-8"), name),
        })
    if not runs:
        sys.exit(f"{raw}: no run directories")
    (out / "runs.json").write_text(json.dumps({"buildPorcelain": porcelain, "runs": runs}, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {len(runs)} runs to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
