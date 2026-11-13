#!/usr/bin/env python3
"""Measure every process of every full sweep under raw/ into results/<RUN_ID>/<process>.json.

A sweep is raw/<RUN_ID>/ with run.json (run.sh). Each process directory is named
sizes-<enc>-p<P>-c<C>-r<n>, cost-p<P>-c<C>-r<n>-<on|off> or noise-p10-c5-<a|b>; its result holds
the sweep's provenance (meta), the process's parameters (params) and its figures: the sizes and
replays of a sizes process, the cost figures of a cost or noise process, and the record check of
a recording-on cost process. A smoke sweep (run.sh CELLS=... or other constants) is skipped;
regenerate.py would refuse it anyway.

Usage: collect.py [--raw <dir>] [--results <dir>]
"""
import argparse
import json
import pathlib
import re
import sys

import regenerate

TOPIC = pathlib.Path(__file__).resolve().parent
NAME = re.compile(r"(?:sizes-(?P<enc>messagepack|json)-p(?P<sp>\d+)-c(?P<sc>\d+)-r(?P<sr>\d+)"
                  r"|cost-p(?P<cp>\d+)-c(?P<cc>\d+)-r(?P<cr>\d+)-(?P<side>on|off)"
                  r"|noise-p(?P<np>\d+)-c(?P<nc>\d+)-(?P<ns>[ab]))")


# run.sh passes ServerLoadTest absolute paths under the topic (--record-dir, --stream-dir), and
# the result's commandLine records them as run: in the checkout the sweep ran in, which isn't
# where the results are read. The result keeps them relative to the topic directory.
TOPIC_PREFIX = re.compile(r"(?:^|(?<==))/\S*?/deep-research/recomputation-cost/")


def portable_command(argv: list, name: str) -> str:
    """The command line with every path under the topic relative to it; exits on any other
    absolute path, which a committed result must not carry."""
    out = []
    for arg in argv:
        arg = TOPIC_PREFIX.sub("", str(arg))
        if re.search(r"(?:^|=)/", arg):
            sys.exit(f"{name}: command line argument {arg!r} is an absolute path outside the topic")
        out.append(arg)
    return " ".join(out)


def params(name: str, loadtest: dict) -> dict:
    m = NAME.fullmatch(name)
    if not m:
        sys.exit(f"{name}: not a process directory run.sh writes")
    config = loadtest["metadata"]["loadTestConfig"]
    common = {"rooms": config["rooms"], "steadySeconds": config["steadySeconds"],
              "startedAt": loadtest["metadata"]["timestampUTC"]}
    if m["enc"]:
        out = {"kind": "sizes", "encoding": m["enc"], "players": int(m["sp"]), "cadence": int(m["sc"]),
               "repeat": int(m["sr"]), "side": "on"}
    elif m["side"]:
        out = {"kind": "cost", "encoding": "messagepack", "players": int(m["cp"]), "cadence": int(m["cc"]),
               "repeat": int(m["cr"]), "side": m["side"]}
    else:
        out = {"kind": "noise", "encoding": "messagepack", "players": int(m["np"]), "cadence": int(m["nc"]),
               "repeat": 0, "side": m["ns"]}
    # The directory name is what run.sh meant; the result file says what ran.
    enc = config.get("transportEncoding", {}).get("message")
    if (config["playersPerRoom"], config["inputCadenceTicks"], config["record"], enc) != \
            (out["players"], out["cadence"], "off" if out["side"] in ("off", "a", "b") else "on", out["encoding"]):
        sys.exit(f"{name}: loadtest.json has players {config['playersPerRoom']}, cadence {config['inputCadenceTicks']}, "
                 f"record {config['record']}, encoding {enc}")
    return {**out, **common}


def collect(raw: pathlib.Path, results: pathlib.Path) -> list:
    written = []
    for record_path in sorted(raw.glob("*/run.json")):
        sweep, record = record_path.parent, json.loads(record_path.read_text(encoding="utf-8"))
        constants = {k: record.get(k) for k in regenerate.CONSTANTS}
        if record.get("onlyCells") or constants != regenerate.CONSTANTS:
            print(f"skipping {sweep.name}: a smoke sweep (cells {record.get('onlyCells')}, {constants})", file=sys.stderr)
            continue
        if not record.get("endedAt"):
            print(f"skipping {sweep.name}: not finished", file=sys.stderr)
            continue
        for d in sorted(p for p in sweep.iterdir() if p.is_dir() and not p.name.startswith(".")):
            loadtest = json.loads((d / "loadtest.json").read_text(encoding="utf-8"))
            meta = loadtest["metadata"]
            p = params(d.name, loadtest)
            out = {
                "name": f"{sweep.name}/{d.name}",
                "meta": {
                    "git_sha": (record.get("git") or {}).get("commit"),
                    "git_dirty": (record.get("git") or {}).get("dirty"),
                    "swift_version": record.get("swiftVersion"),
                    "build_config": meta["build"]["configuration"],
                    "pin_cpus": record.get("pinCpus"),
                    "command": portable_command(meta["commandLine"], f"{sweep.name}/{d.name}"),
                    **constants,
                },
                "params": p,
                "tickIntervalMs": meta["loadTestConfig"]["tickIntervalMs"],
                # The joinResponse features every join was given (null: none agreed); absent in
                # a result written before ServerLoadTest recorded them.
                "wire": {"recorded": "stateUpdateFeatures" in loadtest["results"],
                         "stateUpdateFeatures": loadtest["results"].get("stateUpdateFeatures"),
                         "joinFeatures": loadtest["results"].get("joinFeatures")},
            }
            if p["kind"] == "sizes":
                out["sizes"] = regenerate.measure_run(d)
                out["replay"] = regenerate.replay_figures(d)
            else:
                out["cost"] = regenerate.cost_figures(d, loadtest)
                if p["side"] == "on":
                    check = d / "record-check.json"
                    out["recordCheck"] = json.loads(check.read_text(encoding="utf-8")) if check.exists() else None
            target = results / sweep.name / f"{d.name}.json"
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(json.dumps(out, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            written.append(out["name"])
    return written


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", type=pathlib.Path, default=TOPIC / "raw")
    ap.add_argument("--results", type=pathlib.Path, default=TOPIC / "results")
    args = ap.parse_args()
    for name in collect(args.raw, args.results):
        print(name)


if __name__ == "__main__":
    main()
