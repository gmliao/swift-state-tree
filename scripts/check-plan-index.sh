#!/usr/bin/env bash
# The plan status index (Notes/plans/README.md) merges with git's union driver (.gitattributes):
# a local `git merge origin/main` keeps both sides' lines instead of a conflict. When one side
# changed a row (its status) and the other added a row beside it, both versions of the changed row
# survive. This check fails on a plan linked from more than one row, and on a leftover conflict
# marker, so the duplicate is resolved by hand before the push.
#
# Usage: scripts/check-plan-index.sh [--self-test]
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 - "$@" <<'PY'
import collections
import pathlib
import re
import sys

INDEX = "Notes/plans/README.md"
LINK = re.compile(r"\]\(([^)\s]+\.md)\)")
MARKER = re.compile(r"^(<<<<<<<|=======|>>>>>>>)( |$)")


def errors_in(text, name=INDEX):
    errors, rows = [], collections.defaultdict(list)
    for number, line in enumerate(text.splitlines(), 1):
        if MARKER.match(line):
            errors.append(f"{name}:{number}: a conflict marker")
        if line.startswith("|"):
            m = LINK.search(line)
            if m:
                rows[m.group(1)].append(number)
    for plan, lines in sorted(rows.items()):
        if len(lines) > 1:
            errors.append(f"{name}: {plan} has {len(lines)} rows (lines {', '.join(map(str, lines))}); "
                          "a union merge keeps both versions of a changed row: keep the current one")
    return errors, len(rows)


def self_test():
    head = "| Date | Plan | Status | Evidence |\n|---|---|---|---|\n"
    row = lambda plan, status: f"| 2026-11-19 | [P]({plan}) | {status} | x |\n"
    cells = [
        ("one row per plan", head + row("a.md", "open") + row("b.md", "done"), None),
        ("a status change merged by union beside a new row",
         head + row("a.md", "done") + row("a.md", "proposed") + row("b.md", "open"), "a.md has 2 rows"),
        ("the same plan in two tables", head + row("a.md", "open") + "\n## Done\n\n" + head + row("a.md", "done"), "a.md has 2 rows"),
        ("a leftover conflict marker", head + "<<<<<<< HEAD\n" + row("a.md", "open") + "=======\n>>>>>>> origin/main\n", "conflict marker"),
        ("a link in the prose, not a row", "See [the plan](a.md).\n\n" + head + row("a.md", "open"), None),
        ("a row with two links counts its first", head + "| 2026-11-19 | [P](a.md) | open | after [Q](b.md) |\n" + row("b.md", "open"), None),
    ]
    failed = 0
    for name, text, want in cells:
        errors, _ = errors_in(text, "t.md")
        ok = (not errors) if want is None else any(want in e for e in errors)
        print(f"{'ok  ' if ok else 'FAIL'} self-test: {name}" + ("" if ok else f": {errors}"))
        failed += not ok
    return failed


if sys.argv[1:2] == ["--self-test"]:
    sys.exit(1 if self_test() else 0)
errors, plans = errors_in(pathlib.Path(INDEX).read_text(encoding="utf-8"))
for e in errors:
    print(f"::error::{e}")
if not errors:
    print(f"plan index: {plans} plans, one row each, no conflict marker")
sys.exit(1 if errors else 0)
PY
