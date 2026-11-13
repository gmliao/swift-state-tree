#!/usr/bin/env python3
"""The run record of one run.sh invocation: raw/<RUN_ID>/run.json (stdlib only).

  runmeta.py start <dir> <run-id> <repeat> <order> <capture> <pin-cpus> <reserved> <overwrite> [<cells> [<forms>]]

The arguments follow the other topics' runmeta.py (deep-research/test_runmeta_dirty.py starts every
topic's with the same ones): <capture> 1 is the capture block (its repeat is ignored), 0 a measured
repeat; <reserved> is unused.
  runmeta.py cell <dir> <tag> <status>
  runmeta.py end <dir>
  runmeta.py supersede <dir> <reason>

``start`` writes the record: the kind (``measured``, one repeat, or ``capture``, the capture
block), the repeat and its form order (repeats 1 and 4 forward, 2 and 3 reverse), the git commit
and whether the tree was dirty, the git tree IDs of ``Sources`` and ``Package.swift`` (the
Sources this run measured, compared with the rerun's by regenerate.py), ``swift --version``,
``node --version``, the start time, and the server variables run.sh unset (``serverenv.py``: each
must be recorded as null). Given an existing record, it refuses unless <overwrite> is 1 and the
kind and repeat are the same; it then appends a redo entry. ``cell`` appends a cell's status as it
finishes; ``end`` sets the end time. ``supersede`` marks a run replaced by a later one of the same
kind and repeat, so collect.py skips it.
"""
import datetime, json, pathlib, subprocess, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import gitstate  # noqa: E402  (the dirty rule, one for every topic)
import serverenv  # noqa: E402  (the server variables run.sh unsets; one list for every topic)

KINDS = ("measured", "capture")
REPEATS = (1, 2, 3, 4)
# ABBA over the repeats: within a point, 1 and 4 run the forms in run.sh's order, 2 and 3 reversed.
ORDER = {1: "forward", 2: "reverse", 3: "reverse", 4: "forward"}


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def output(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, check=True, encoding="utf-8").stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def load(directory):
    return json.loads((directory / "run.json").read_text(encoding="utf-8"))


def save(directory, record):
    path = directory / "run.json"
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def start(directory, run_id, repeat, order, capture, pin_cpus, reserved, overwrite, cells="", forms=""):
    kind = "capture" if capture == "1" else "measured"
    repeat = int(repeat) if kind == "measured" else None
    if kind == "measured" and repeat not in REPEATS:
        sys.exit(f"repeat must be one of {REPEATS}, not {repeat}")
    if kind == "measured" and order != ORDER[repeat]:
        sys.exit(f"repeat {repeat} runs in {ORDER[repeat]!r} order, not {order!r}")
    directory.mkdir(parents=True, exist_ok=True)
    if (directory / "run.json").exists():
        record = load(directory)
        if overwrite != "1":
            sys.exit(f"{directory}/run.json exists: RUN_ID {run_id} was already run (set OVERWRITE=1 to redo cells in it)")
        if (record["kind"], record["repeat"]) != (kind, repeat):
            sys.exit(f"{directory}/run.json is {record['kind']} repeat {record['repeat']}, not {kind} repeat {repeat}")
        record.setdefault("redos", []).append({"at": now(), "pinCpus": pin_cpus, "serverEnv": serverenv.record()})
        record["endedAt"] = None
        save(directory, record)
        return
    commit = output("git", "rev-parse", "HEAD")
    # Tracked changes, and untracked files outside this topic's raw/, data/ and results/ (gitstate.py).
    status = gitstate.dirt(pathlib.Path(__file__).resolve().parent)
    swift = output("swift", "--version")
    save(directory, {
        "runId": run_id,
        "kind": kind,
        "repeat": repeat,
        "order": ORDER.get(repeat, "forward"),
        # run.sh runs every capture pass with SWIFT_DETERMINISTIC_HASHING=1, and no measured pass.
        "deterministicHashing": kind == "capture",
        "pinCpus": pin_cpus,
        "serverEnv": serverenv.record(),
        "onlyCells": cells.split() or None,
        "onlyForms": forms.split() or None,
        "git": {
            "commit": commit,
            "dirty": None if commit is None else bool(status),
            "sourcesTree": output("git", "rev-parse", "HEAD:Sources"),
            "packageTree": output("git", "rev-parse", "HEAD:Package.swift"),
        },
        "swiftVersion": swift.splitlines()[0] if swift else None,
        "nodeVersion": output("node", "--version"),
        "startedAt": now(),
        "endedAt": None,
        "superseded": None,
        "cells": [],
    })


def main(argv):
    command, directory = argv[0], pathlib.Path(argv[1])
    if command == "start":
        start(directory, *argv[2:12])
    elif command == "cell":
        record = load(directory)
        record["cells"].append({"tag": argv[2], "status": argv[3], "finishedAt": now()})
        save(directory, record)
    elif command == "end":
        record = load(directory)
        record["endedAt"] = now()
        save(directory, record)
    elif command == "supersede":
        record = load(directory)
        record["superseded"] = {"at": now(), "reason": argv[2]}
        save(directory, record)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
