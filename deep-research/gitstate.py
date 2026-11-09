#!/usr/bin/env python3
"""Whether the checkout is dirty for a topic's run (stdlib and git only).

A run records `git.dirty` (each topic's `runmeta.py start`), and the topics refuse a dirty run.
The rule: the checkout is dirty when `git status` shows any tracked change, staged or not, or
any untracked file outside the topic's own output directories (`raw/`, `data/`, `results/` under
the topic). A sweep's earlier invocations write there: network-impairment ingests each run into
`results/` during the host procedure, so its next RUN_ID (the SR step) would otherwise start
dirty. An untracked file anywhere else, a source not yet committed, still counts, and so does a
tracked file under the output directories that was changed.

The cost of the rule: a stale untracked file left in `results/` by an earlier, aborted sweep
doesn't mark the next run dirty. Each result carries its own run's commit and dirty flag, and
provenance refuses results from more than one commit, so a stale one is still caught at the
tables; the host checks that `results/` and `data/` hold nothing untracked before a procedure.
"""
from __future__ import annotations

import pathlib
import subprocess

OUTPUT_DIRS = ("raw", "data", "results")


def entries(porcelain_z: str) -> list[tuple[str, str]]:
    """(status, path) per entry of `git status --porcelain -z`. A rename or copy's second field
    (its source path) belongs to the entry before it and isn't an entry of its own."""
    out, fields, i = [], porcelain_z.split("\0"), 0
    while i < len(fields):
        field = fields[i]
        i += 1
        if not field:
            continue
        status, path = field[:2], field[3:]
        out.append((status, path))
        if status[0] in "RC":
            i += 1  # the source path
    return out


def dirt(topic: pathlib.Path) -> list[str]:
    """The entries that make the checkout dirty for a run of `topic` (empty: clean). A git that
    can't report its status counts as dirty."""
    topic = pathlib.Path(topic).resolve()
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=topic, capture_output=True, text=True)
    status = subprocess.run(["git", "status", "--porcelain", "-z", "--untracked-files=all"], cwd=topic,
                            capture_output=True, text=True)
    if top.returncode != 0 or status.returncode != 0:
        return [f"git status failed: {(status.stderr or top.stderr).strip()}"]
    rel = topic.relative_to(pathlib.Path(top.stdout.strip()).resolve()).as_posix()
    own = tuple(f"{rel}/{d}/" for d in OUTPUT_DIRS)
    return [f"{s} {p}" for s, p in entries(status.stdout) if not (s == "??" and p.startswith(own))]
