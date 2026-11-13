#!/usr/bin/env python3
"""The effective wire form of a run: its encoding, and whether the path index, field merge and
row addressing were on (stdlib and git only).

The defaults changed in November 2026 (field merge on by default since #301, the path index since
#308), so a run's numbers are only comparable with runs of the same form. Each tool records what
it used: EncodingBenchmark's results metadata has ``pathIndex`` and ``fieldMerge``, and
ws-loadtest and ServerLoadTest record the server's ``joinResponse.stateUpdateFeatures``.

Row addressing (#392) is decided by evidence: a recorded feature list with ``rowAddressing`` is
on, a list without it is off (before or after its default changed), and a caller that knows the
run couldn't have it (an EncodingBenchmark run off the router path) passes ``row_addressing``.
Only a run with no list and no value falls back to ancestry, against the feature's introduction.

A run that doesn't record a knob is resolved by **ancestry**, never by date: if its recorded
commit doesn't contain the knob's merge commit (``KNOBS``), the knob didn't exist and the run had
it off. If the commit contains the knob, or isn't known to the repository, or the run recorded no
commit, the form is a missing input (``MissingWireForm``). A topic's regenerate turns that into
its own "fail (missing: ...)" or refusal.

Use from a topic directory::

    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
    import wireform

    form = wireform.resolve(commit, "messagepack", path_index=meta.get("pathIndex"),
                            field_merge=meta.get("fieldMerge"))
    form = wireform.resolve(commit, "messagepack", features=run.get("stateUpdateFeatures"))
    # ws-loadtest: phaseTotals.stateUpdateFeatures summed over the phases
    joined = wireform.join_form(counts)   # None: not recorded, resolve falls back to ancestry
    encoding, features = joined if joined else (declared_encoding, None)
    form = wireform.resolve(commit, encoding, features=features)
    problems = wireform.check({"run-a": form_a, "run-b": form_b}, intended)
    caption = form.caption()   # "messagepack, pathIndex off, fieldMerge off" (", rowAddressing on" when on)

Run the tests: python3 deep-research/test_wireform.py
"""
from __future__ import annotations

import dataclasses
import functools
import pathlib
import subprocess

REPO = pathlib.Path(__file__).resolve().parent.parent

# Merge commit that added each knob: a run whose commit doesn't contain it ran with it off.
# (#308, 49fde351, changed the path index's default; it didn't add a knob, so it isn't here:
# a run between #297 and #308 records the field, whatever its value.)
KNOBS = {
    "pathIndex": "a9cbed9b",  # #297
    "fieldMerge": "b6669cd9",  # #301
    "rowAddressing": "6f7920c0",  # #491 (exp/next merged into main), which brought it in, off by default
}

# Branch commits a squash merge removed from history, recorded by runs made on the branch, mapped
# to the squash merge that brought their code in. The branch was based on main before that merge,
# so if the merge doesn't contain a knob, neither did the run. Only for captioning pre-refreeze
# records (runs from before both knobs); a new entry names the PR it came in with, and
# test_wireform.py checks every entry (the key unknown to the repository, the merge known and
# containing neither knob). A run may record the short or the full SHA: keys match by prefix.
SQUASHED = {
    "b8e798b": "c0118d6b",  # snapshot-baseline results, #56
}


def squashed_merge(commit: str) -> str | None:
    """The squash merge ``SQUASHED`` maps ``commit`` to (matched by a prefix of at least 7 hex
    digits, either way round), or ``None``."""
    if len(commit) < 7:
        return None
    hits = {merge for key, merge in SQUASHED.items() if key.startswith(commit) or commit.startswith(key)}
    return hits.pop() if len(hits) == 1 else None


class MissingWireForm(ValueError):
    """The run's wire form can't be told: say which part and why."""


@dataclasses.dataclass(frozen=True)
class WireForm:
    encoding: str
    path_index: bool
    field_merge: bool
    row_addressing: bool

    def caption(self) -> str:
        """The form in words. Row addressing is named only when on, so captions of runs without it
        read as they did before the field existed."""
        on = lambda v: "on" if v else "off"
        rows = ", rowAddressing on" if self.row_addressing else ""
        return f"{self.encoding}, pathIndex {on(self.path_index)}, fieldMerge {on(self.field_merge)}{rows}"

    def as_dict(self) -> dict:
        return {"encoding": self.encoding, "pathIndex": self.path_index, "fieldMerge": self.field_merge,
                "rowAddressing": self.row_addressing}


@functools.lru_cache(maxsize=None)
def contains(commit: str, knob_commit: str, repo: pathlib.Path = REPO) -> bool | None:
    """Whether ``commit`` has ``knob_commit`` in its history; ``None`` when git can't tell (an
    unknown commit, or no repository)."""
    try:
        done = subprocess.run(["git", "-C", str(repo), "merge-base", "--is-ancestor", knob_commit, commit],
                              capture_output=True, text=True)
    except OSError:
        return None
    return {0: True, 1: False}.get(done.returncode)


def _knob(name: str, recorded, commit: str | None, repo: pathlib.Path) -> bool:
    if recorded is not None:
        if not isinstance(recorded, bool):
            raise MissingWireForm(f"{name} is {recorded!r}, not a boolean")
        return recorded
    if not commit:
        raise MissingWireForm(f"{name} not recorded and the run has no commit")
    has = contains(squashed_merge(commit) or commit, KNOBS[name], repo)
    if has is None:
        raise MissingWireForm(f"{name} not recorded and commit {commit} is unknown to the repository")
    if has:
        raise MissingWireForm(f"{name} not recorded although commit {commit} contains it ({KNOBS[name]})")
    return False


def resolve(commit: str | None, encoding: str | None, *, path_index=None, field_merge=None,
            row_addressing=None, features=None, repo: pathlib.Path = REPO) -> WireForm:
    """The run's form. ``path_index`` / ``field_merge`` / ``row_addressing``: what the run recorded
    (``None``: not recorded). ``features``: the joinResponse's ``stateUpdateFeatures`` instead
    (``None``: not recorded; a list, even empty, decides all three)."""
    if not isinstance(encoding, str) or not encoding:
        raise MissingWireForm(f"encoding {encoding!r} not recorded")
    if features is not None:
        if path_index is not None or field_merge is not None or row_addressing is not None:
            raise ValueError("pass the features or the knobs, not both")
        if not isinstance(features, list) or not all(isinstance(f, str) for f in features):
            raise MissingWireForm(f"stateUpdateFeatures is {features!r}, not a list of names")
        path_index, field_merge = "pathIndex" in features, "fieldMerge" in features
        row_addressing = "rowAddressing" in features
    return WireForm(encoding, _knob("pathIndex", path_index, commit, repo), _knob("fieldMerge", field_merge, commit, repo),
                    _knob("rowAddressing", row_addressing, commit, repo))


def join_form(counts: dict[str, int] | None) -> tuple[str | None, list[str]] | None:
    """The one wire form a run's joins were given, ``(encoding, features)``, from ws-loadtest's
    per-phase join counts (``phaseTotals.stateUpdateFeatures``, keyed ``<encoding>:<features>``,
    e.g. ``"messagepack:fieldMerge,pathIndex"`` or ``"json:none"``; sum the phases first). The
    encoding is ``None`` when the server named none (``"unknown"``). ``None`` when no join was
    counted (not recorded: ``resolve`` falls back to ancestry). Joins given different forms, or
    a key without the encoding part, are ``MissingWireForm``."""
    keys = sorted(k for k, n in (counts or {}).items() if n)
    if not keys:
        return None
    if len(keys) > 1:
        raise MissingWireForm(f"joins were given different wire forms: {dict(sorted(counts.items()))}")
    encoding, sep, features = keys[0].partition(":")
    if not sep:
        raise MissingWireForm(f"join key {keys[0]!r} has no encoding (a client before the <encoding>:<features> key)")
    return (None if encoding == "unknown" else encoding, [] if features == "none" else features.split(","))


def check(forms: dict[str, WireForm], intended: WireForm) -> list[str]:
    """One line per run whose form isn't ``intended`` (sorted by run id); empty when all match."""
    return [f"{rid}: {form.caption()}, intended {intended.caption()}"
            for rid, form in sorted(forms.items()) if form != intended]
