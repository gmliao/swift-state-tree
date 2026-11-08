#!/usr/bin/env python3
"""The effective wire form of a run: its encoding, and whether the path index and field merge
were on (stdlib and git only).

The defaults changed in November 2026 (field merge on by default since #301, the path index since
#308), so a run's numbers are only comparable with runs of the same form. Each tool records what
it used: EncodingBenchmark's results metadata has ``pathIndex`` and ``fieldMerge``, and
ws-loadtest and ServerLoadTest record the server's ``joinResponse.stateUpdateFeatures``.

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
    problems = wireform.check({"run-a": form_a, "run-b": form_b}, intended)
    caption = form.caption()   # "messagepack, pathIndex off, fieldMerge off"

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
}

class MissingWireForm(ValueError):
    """The run's wire form can't be told: say which part and why."""


@dataclasses.dataclass(frozen=True)
class WireForm:
    encoding: str
    path_index: bool
    field_merge: bool

    def caption(self) -> str:
        on = lambda v: "on" if v else "off"
        return f"{self.encoding}, pathIndex {on(self.path_index)}, fieldMerge {on(self.field_merge)}"

    def as_dict(self) -> dict:
        return {"encoding": self.encoding, "pathIndex": self.path_index, "fieldMerge": self.field_merge}


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
    has = contains(commit, KNOBS[name], repo)
    if has is None:
        raise MissingWireForm(f"{name} not recorded and commit {commit} is unknown to the repository")
    if has:
        raise MissingWireForm(f"{name} not recorded although commit {commit} contains it ({KNOBS[name]})")
    return False


def resolve(commit: str | None, encoding: str | None, *, path_index=None, field_merge=None,
            features=None, repo: pathlib.Path = REPO) -> WireForm:
    """The run's form. ``path_index`` / ``field_merge``: what the run recorded (``None``: not
    recorded). ``features``: the joinResponse's ``stateUpdateFeatures`` instead (``None``: not
    recorded; a list, even empty, decides both knobs)."""
    if not isinstance(encoding, str) or not encoding:
        raise MissingWireForm(f"encoding {encoding!r} not recorded")
    if features is not None:
        if path_index is not None or field_merge is not None:
            raise ValueError("pass the features or the knobs, not both")
        if not isinstance(features, list) or not all(isinstance(f, str) for f in features):
            raise MissingWireForm(f"stateUpdateFeatures is {features!r}, not a list of names")
        path_index, field_merge = "pathIndex" in features, "fieldMerge" in features
    return WireForm(encoding, _knob("pathIndex", path_index, commit, repo), _knob("fieldMerge", field_merge, commit, repo))


def check(forms: dict[str, WireForm], intended: WireForm) -> list[str]:
    """One line per run whose form isn't ``intended`` (sorted by run id); empty when all match."""
    return [f"{rid}: {form.caption()}, intended {intended.caption()}"
            for rid, form in sorted(forms.items()) if form != intended]
