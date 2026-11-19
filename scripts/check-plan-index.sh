#!/usr/bin/env bash
# The plan status index (Notes/plans/README.md) merges with git's union driver (.gitattributes):
# a local `git merge origin/main` keeps both sides' lines instead of a conflict. When one side
# changed a row (its status) and the other added a row beside it, both versions of the changed row
# survive. This check fails on a plan with more than one row, and on a leftover conflict marker, so
# the duplicate is resolved by hand before the push.
#
# A plan is the target of the link in a table row's Plan column (the column headed `Plan`),
# normalized: `<…>`, a `#fragment` and a title dropped, `./` and `a/../` resolved. Rows with or
# without the outer `|` count; lines inside a fenced code block don't. A row whose Plan cell has no
# link fails: it can't be checked.
#
# Conflict markers: `<<<<<<< `, `||||||| ` (diff3) and `>>>>>>> ` lines each fail. A bare `=======`
# line is a setext heading underline in Markdown, so it fails only beside one of the others.
#
# Usage: scripts/check-plan-index.sh [--self-test]
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 - "$@" <<'PY'
import collections
import pathlib
import posixpath
import re
import sys

INDEX = "Notes/plans/README.md"
# A link's target: `](<target>)` or `](target)`, with an optional title after it.
LINK = re.compile(r"\]\(\s*(?:<([^>]*)>|([^)\s]+))(?:\s+\"[^\"]*\")?\s*\)")
MARKER = re.compile(r"^(<<<<<<<|\|\|\|\|\|\|\||>>>>>>>)( |$)")
SEPARATOR = re.compile(r"^=======\s*$")
DELIMITER_CELL = re.compile(r"^\s*:?-+:?\s*$")
FENCE = re.compile(r"^\s{0,3}(```|~~~)")


def cells(line):
    """A table row's cells, with or without the outer pipes."""
    body = line.strip()
    if body.startswith("|"):
        body = body[1:]
    if body.endswith("|") and not body.endswith("\\|"):
        body = body[:-1]
    return [c.strip() for c in re.split(r"(?<!\\)\|", body)]


def is_delimiter(line):
    if "-" not in line or "|" not in line:
        return False
    return all(DELIMITER_CELL.match(p) for p in cells(line))


def normalize(target):
    target = target.split("#", 1)[0]
    return posixpath.normpath(target) if target else target


def errors_in(text, name=INDEX):
    errors, rows = [], collections.defaultdict(list)
    lines = text.splitlines()
    markers = [i for i, line in enumerate(lines, 1) if MARKER.match(line)]
    if markers:
        markers += [i for i, line in enumerate(lines, 1) if SEPARATOR.match(line)]
    for number in sorted(markers):
        errors.append(f"{name}:{number}: a conflict marker")
    fenced, plan_column, i = False, None, 0
    while i < len(lines):
        line = lines[i]
        if FENCE.match(line):
            fenced, plan_column = not fenced, None
        elif fenced:
            pass
        elif plan_column is None:
            # A table starts with a header row and its delimiter row.
            if "|" in line and i + 1 < len(lines) and is_delimiter(lines[i + 1]):
                header = [c.lower() for c in cells(line)]
                plan_column = header.index("plan") if "plan" in header else -1
                i += 1
        elif "|" not in line or not line.strip():
            plan_column = None  # the table ended
        elif plan_column >= 0:
            row = cells(line)
            m = LINK.search(row[plan_column]) if plan_column < len(row) else None
            if m:
                rows[normalize(m.group(1) if m.group(1) is not None else m.group(2))].append(i + 1)
            else:
                errors.append(f"{name}:{i + 1}: a row with no plan link in its Plan column")
        i += 1
    for plan, numbers in sorted(rows.items()):
        if len(numbers) > 1:
            errors.append(f"{name}: {plan} has {len(numbers)} rows (lines {', '.join(map(str, numbers))}); "
                          "a union merge keeps both versions of a changed row: keep the current one")
    return errors, len(rows)


def self_test():
    head = "| Date | Plan | Status | Evidence |\n|---|---|---|---|\n"
    row = lambda plan, status="open": f"| 2026-11-19 | [P]({plan}) | {status} | x |\n"
    two = "a.md has 2 rows"
    cells_ = [
        ("one row per plan", head + row("a.md") + row("b.md", "done"), None),
        ("a status change merged by union beside a new row", head + row("a.md", "done") + row("a.md", "proposed") + row("b.md"), two),
        ("the same plan in two tables", head + row("a.md") + "\n## Done\n\n" + head + row("a.md", "done"), two),
        ("./a.md and a.md are one plan", head + row("./a.md") + row("a.md", "done"), two),
        ("a fragment is the same plan", head + row("a.md#status") + row("a.md", "done"), two),
        ("an angle-bracket link is the same plan", head + row("<a.md>") + row("a.md", "done"), two),
        ("a link with a title is the same plan", head + "| 2026-11-19 | [P](a.md \"t\") | open | x |\n" + row("a.md", "done"), two),
        ("a/../a.md is a.md", head + row("specs/../a.md") + row("a.md", "done"), two),
        ("a row without the outer pipes counts", head + "2026-11-19 | [P](a.md) | open | x\n" + row("a.md", "done"), two),
        ("a link in Evidence isn't the plan", head + "| 2026-11-19 | [P](a.md) | open | after [Q](b.md) |\n" + row("b.md"), None),
        ("a Plan cell without a link fails", head + "| 2026-11-19 | a.md | open | [Q](b.md) |\n", "no plan link"),
        ("a table without a Plan column isn't read", "| Status | Meaning |\n|---|---|\n| open | [x](a.md) |\n| done | [x](a.md) |\n", None),
        ("a fenced example isn't read", head + row("a.md") + "\n```\n" + head + row("a.md") + "```\n", None),
        ("a link in the prose isn't a row", "See [the plan](a.md).\n\n" + head + row("a.md"), None),
        ("a <<<<<<< line fails", head + "<<<<<<< HEAD\n" + row("a.md"), "conflict marker"),
        ("a ||||||| line fails (diff3)", head + row("a.md") + "||||||| base\n", "conflict marker"),
        ("a >>>>>>> line fails", head + row("a.md") + ">>>>>>> origin/main\n", "conflict marker"),
        ("a ======= line beside a marker fails", "<<<<<<< HEAD\n=======\n", ":2: a conflict marker"),
        ("a ======= line alone is a setext underline", "Title\n=======\n\n" + head + row("a.md"), None),
    ]
    failed = 0
    for name, text, want in cells_:
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
