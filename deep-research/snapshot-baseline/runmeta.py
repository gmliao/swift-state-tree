#!/usr/bin/env python3
"""The run record of one run.sh invocation: raw/<RUN_ID>/run.json (stdlib only).

  runmeta.py start <dir> <run-id> <repeat> <order> <verify-views> <pin-cpus> <extra> <overwrite>
  runmeta.py cell <dir> <tag> <status>
  runmeta.py end <dir>
  runmeta.py supersede <dir> <reason>

``start`` writes the record: the options, the git commit (and whether the tree was dirty),
``swift --version``, ``node --version`` and the start time. Given an existing record, it refuses
unless <overwrite> is 1 and the repeat is the same; it then appends a redo entry. ``cell``
appends a cell's status as it finishes; ``end`` sets the end time. ``supersede`` marks a run
replaced by a later one with the same repeat, so collect.py skips it.
"""
import datetime, json, pathlib, subprocess, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
import gitstate  # noqa: E402  (the dirty rule, one for every topic)
import serverenv  # noqa: E402


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def output(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def load(directory):
    return json.loads((directory / "run.json").read_text())


def save(directory, record):
    path = directory / "run.json"
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(record, indent=2) + "\n")
    tmp.replace(path)


def start(directory, run_id, repeat, order, verify_views, pin_cpus, extra, overwrite):
    directory.mkdir(parents=True, exist_ok=True)
    if (directory / "run.json").exists():
        record = load(directory)
        if overwrite != "1":
            sys.exit(f"{directory}/run.json exists: RUN_ID {run_id} was already run (set OVERWRITE=1 to redo cells in it)")
        if record["repeat"] != int(repeat):
            sys.exit(f"{directory}/run.json is repeat {record['repeat']}, not {repeat}")
        record.setdefault("redos", []).append({"at": now(), "serverEnv": serverenv.record(), "order": order, "verifyViews": verify_views == "1",
                                               "pinCpus": pin_cpus, "extra": extra == "1"})
        record["endedAt"] = None
        save(directory, record)
        return
    commit = output("git", "rev-parse", "HEAD")
    # Tracked changes, and untracked files outside this topic's raw/, data/ and results/ (gitstate.py).
    status = gitstate.dirt(pathlib.Path(__file__).resolve().parent)
    swift = output("swift", "--version")
    save(directory, {
        "runId": run_id,
        "repeat": int(repeat),
        "order": order,
        "verifyViews": verify_views == "1",
        "pinCpus": pin_cpus,
        "extra": extra == "1",
        "git": {"commit": commit, "dirty": None if commit is None else bool(status)},
        "swiftVersion": swift.splitlines()[0] if swift else None,
        "nodeVersion": output("node", "--version"),
        "serverEnv": serverenv.record(),
        "startedAt": now(),
        "endedAt": None,
        "superseded": None,
        "cells": [],
    })


def main(argv):
    command, directory = argv[0], pathlib.Path(argv[1])
    if command == "start":
        start(directory, *argv[2:9])
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
