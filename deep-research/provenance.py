#!/usr/bin/env python3
"""The provenance line a topic's regenerate.py writes at the head of its Results: the measured
commit, whether the tree was dirty, and the Swift, Node and build configuration, taken from the
results' meta.

Each topic maps its own meta keys onto `Meta` (its collector names them) and passes one `Meta`
per result file; `line()` checks them and renders the line, so `--check` verifies it with the
rest of the section. It refuses (`Refused`) when a result has no commit, when the results name
more than one commit, or when any result was measured on a dirty tree. The commit is printed as
recorded (a short SHA stays short: results are never rewritten). A Swift, Node or build field a
result doesn't record prints "not recorded"; values that differ between results are all listed.
The Swift version prints as its number only for the forms that hold one and nothing else
(`Swift version 6.2.4 (swift-6.2.4-RELEASE)`, `Swift version 6.2.4`, `Swift 6.2.4`, `6.2.4` all
print 6.2.4); any other
text prints as recorded.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Iterable, Optional

NOT_RECORDED = "not recorded"


class Refused(ValueError):
    """The results can't be given one provenance: say why."""


@dataclass(frozen=True)
class Meta:
    source: str                    # the result file, for messages
    commit: Optional[str]
    dirty: Optional[bool] = None   # None: the result doesn't record it
    swift: Optional[str] = None
    node: Optional[str] = None
    build: Optional[str] = None
    kind: str = ""                 # the topic's own tag for a scope (e.g. "sst"), see line()


def from_results(runs, kind=lambda run: "") -> list[Meta]:
    """One Meta per result in the collectors' snake_case form: meta.git_sha, git_dirty,
    swift_version, node_version, build_config, and source_file for messages."""
    out = []
    for r in runs:
        m = r.get("meta") or {}
        out.append(Meta(m.get("source_file") or r.get("name") or "a result", m.get("git_sha"), m.get("git_dirty"), m.get("swift_version"),
                        m.get("node_version"), m.get("build_config"), kind=kind(r)))
    return out


def swift_display(recorded: str) -> str:
    """6.2.4 from `Swift version 6.2.4 (swift-6.2.4-RELEASE)`, `Swift 6.2.4` or `6.2.4`; else as recorded."""
    v = r"(\d+\.\d+(?:\.\d+)?)"
    m = (re.fullmatch(rf"Swift version {v} \(swift-{v}-RELEASE\)", recorded)
         or re.fullmatch(rf"(?:Swift |Swift version )?{v}", recorded))
    return m.group(1) if m and len(set(m.groups())) == 1 else recorded


def _values(metas: list[Meta], field: str, show=lambda v: v) -> str:
    seen = sorted({show(getattr(m, field)) for m in metas if getattr(m, field) not in (None, "")})
    missing = sum(1 for m in metas if getattr(m, field) in (None, ""))
    if not seen:
        return NOT_RECORDED
    text = " / ".join(seen)
    return text if not missing else f"{text} ({NOT_RECORDED} in {missing} of {len(metas)})"


def check(metas: Iterable[Meta]) -> list[Meta]:
    metas = list(metas)
    for m in metas:
        if not m.commit:
            raise Refused(f"{m.source}: no commit in its meta")
        if m.dirty:
            raise Refused(f"{m.source}: measured on a dirty tree at {m.commit}")
    commits = sorted({m.commit for m in metas})
    if len(commits) > 1:
        raise Refused(f"results from {len(commits)} commits ({', '.join(commits)}): one table is one commit's")
    return metas


def line(metas: Iterable[Meta], label: str = "", scopes: Optional[dict] = None, node: bool = True) -> Optional[str]:
    """The provenance line, or None for no results; raises Refused (see the module docstring).

    `scopes` maps a field ("swift", "node", "build") to (name, kinds): that field is read only
    from the results whose `kind` is in `kinds`, and is followed by `(name)`. For a topic whose
    baseline files carry no Swift build, say. `node=False` leaves Node out, for a topic with no
    Node process in what it measures."""
    metas = check(metas)
    if not metas:
        return None
    scopes = scopes or {}

    def field(name: str, show=lambda v: v) -> str:
        if name not in scopes:
            return _values(metas, name, show)
        scope, kinds = scopes[name]
        return f"{_values([m for m in metas if m.kind in kinds], name, show)} ({scope})"

    flags = {m.dirty for m in metas}
    tree = "clean tree" if flags == {False} else ("dirty flag " + NOT_RECORDED if flags == {None}
                                                  else f"clean tree ({NOT_RECORDED} in {sum(1 for m in metas if m.dirty is None)} of {len(metas)})")
    head = f"Provenance{' (' + label + ')' if label else ''}, from the results' meta: "
    return (f"{head}commit `{metas[0].commit}`, {tree}; Swift {field('swift', swift_display)}; "
            + (f"Node {field('node')}; " if node else "") + f"build {field('build')}.")
