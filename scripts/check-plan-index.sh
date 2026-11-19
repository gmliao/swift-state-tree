#!/usr/bin/env bash
# The plan status index (Notes/plans/README.md) merges with git's union driver (.gitattributes):
# a local `git merge origin/main` keeps both sides' lines instead of a conflict. When one side
# changed a row (its status) and the other added a row beside it, both versions of the changed row
# survive. This check fails on a plan with more than one row, and on a leftover conflict marker, so
# the duplicate is resolved by hand before the push.
#
# A plan is the target of the first link in a table row's Plan column (the column headed `Plan`):
# an inline link (`[t](target)`, with an optional "…", '…' or (…) title) or a reference link
# (`[t][ref]`, `[ref][]`, `[ref]`, defined by a `[ref]: target` line). Code spans and images in the
# cell are skipped. The target is normalized: `<…>` and a `#fragment` dropped, `./` and `a/../`
# resolved. Rows with or without the outer `|` count, and `\|` doesn't split a cell. Lines inside a
# fenced code block don't count; a fence closes on its own character, at least as long. A row whose
# Plan cell has no link fails, and so does an index with no Plan row at all.
#
# Conflict markers: `<<<<<<< `, `||||||| ` (diff3) and `>>>>>>> ` lines each fail. A bare `=======`
# line is a setext heading underline in Markdown, so it fails only inside a `<<<<<<<` block.
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
TITLE = r"(?:\s+(?:\"[^\"]*\"|'[^']*'|\([^)]*\)))?"
DESTINATION = r"(?:<([^>]*)>|([^\s()<>]+))"
INLINE = re.compile(r"\]\(\s*" + DESTINATION + TITLE + r"\s*\)")
# `[t][ref]`, `[ref][]` and `[ref]` (not followed by `(` or `[`).
REFERENCE = re.compile(r"\[((?:\\.|[^\]\\])*)\]\[((?:\\.|[^\]\\])*)\]|\[((?:\\.|[^\]\\])+)\](?![(\[])")
DEFINITION = re.compile(r"^ {0,3}\[((?:\\.|[^\]\\])+)\]:\s*" + DESTINATION + TITLE + r"\s*$")
CODE_SPAN = re.compile(r"(`+)(?!`).*?(?<!`)\1(?!`)")
IMAGE = re.compile(r"!\[(?:\\.|[^\]\\])*\](?:\([^)]*\)|\[(?:\\.|[^\]\\])*\])?")
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
OPEN, BASE, SEPARATOR, CLOSE = (re.compile(rf"^{m}( |$)") for m in ("<{7}", r"\|{7}", "={7}", ">{7}"))
DELIMITER_CELL = re.compile(r"^\s*:?-+:?\s*$")


def label(text):
    return " ".join(text.split()).casefold()


def cells(line):
    """A table row's cells, with or without the outer pipes; `\\|` doesn't split."""
    body = line.strip()
    if body.startswith("|"):
        body = body[1:]
    if body.endswith("|") and not body.endswith("\\|"):
        body = body[:-1]
    return [c.strip() for c in re.split(r"(?<!\\)\|", body)]


def is_delimiter(line):
    return "-" in line and "|" in line and all(DELIMITER_CELL.match(p) for p in cells(line))


def normalize(target):
    target = target.split("#", 1)[0]
    return posixpath.normpath(target) if target else target


def fenced_lines(lines):
    """For each line, whether it is a fence line or inside a fenced code block."""
    flags, fence = [], None
    for line in lines:
        m = FENCE.match(line)
        if fence is None:
            if m and not (m.group(1)[0] == "`" and "`" in m.group(2)):
                fence = m.group(1)
            flags.append(fence is not None)
        else:
            flags.append(True)
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) and not m.group(2).strip():
                fence = None
    return flags


def plan_target(cell, definitions):
    """The first link's target in a Plan cell, or None."""
    cell = IMAGE.sub("", CODE_SPAN.sub("", cell))
    inline = INLINE.search(cell)
    for m in REFERENCE.finditer(cell):
        if inline and inline.start() < m.start():
            break
        ref = m.group(2) or m.group(1) if m.group(1) is not None else m.group(3)
        if label(ref) in definitions:
            return definitions[label(ref)]
    if inline:
        return inline.group(1) if inline.group(1) is not None else inline.group(2)
    return None


def errors_in(text, name=INDEX):
    errors, rows = [], collections.defaultdict(list)
    lines = text.splitlines()
    fenced = fenced_lines(lines)
    in_conflict, marker_lines = False, set()
    for number, (line, inside) in enumerate(zip(lines, fenced), 1):
        if inside:
            continue
        if OPEN.match(line):
            in_conflict = True
        if OPEN.match(line) or BASE.match(line) or CLOSE.match(line) or (in_conflict and SEPARATOR.match(line)):
            errors.append(f"{name}:{number}: a conflict marker")
            marker_lines.add(number - 1)
        if CLOSE.match(line):
            in_conflict = False
    definitions = {}
    for line, inside in zip(lines, fenced):
        m = None if inside else DEFINITION.match(line)
        if m:
            definitions.setdefault(label(m.group(1)), m.group(2) if m.group(2) is not None else m.group(3))
    plan_column, i = None, 0
    while i < len(lines):
        line = lines[i]
        if i in marker_lines:
            pass  # reported above; the rows on both sides of a conflict still count
        elif fenced[i]:
            plan_column = None
        elif plan_column is None:
            # A table starts with a header row and its delimiter row.
            if "|" in line and i + 1 < len(lines) and not fenced[i + 1] and is_delimiter(lines[i + 1]):
                header = [c.lower() for c in cells(line)]
                plan_column = header.index("plan") if "plan" in header else -1
                i += 1
        elif "|" not in line or not line.strip():
            plan_column = None  # the table ended
        elif plan_column >= 0:
            row = cells(line)
            target = plan_target(row[plan_column], definitions) if plan_column < len(row) else None
            if target is not None:
                rows[normalize(target)].append(i + 1)
            else:
                errors.append(f"{name}:{i + 1}: a row with no plan link in its Plan column")
        i += 1
    for plan, numbers in sorted(rows.items()):
        if len(numbers) > 1:
            errors.append(f"{name}: {plan} has {len(numbers)} rows (lines {', '.join(map(str, numbers))}); "
                          "a union merge keeps both versions of a changed row: keep the current one")
    if not rows:
        errors.append(f"{name}: no table row with a Plan column: the index's tables weren't found")
    return errors, len(rows)


def self_test():
    head = "| Date | Plan | Status | Evidence |\n|---|---|---|---|\n"
    row = lambda plan, status="open": f"| 2026-11-19 | [P]({plan}) | {status} | x |\n"
    dup = lambda plan, lines: [f"t.md: {plan} has 2 rows (lines {lines}); a union merge keeps both versions of a changed row: keep the current one"]
    marker = lambda *ns: [f"t.md:{n}: a conflict marker" for n in ns]
    none = ["t.md: no table row with a Plan column: the index's tables weren't found"]
    cells_ = [
        ("one row per plan", head + row("a.md") + row("b.md", "done"), []),
        ("a status change merged by union beside a new row", head + row("a.md", "done") + row("a.md", "proposed") + row("b.md"), dup("a.md", "3, 4")),
        ("the same plan in two tables", head + row("a.md") + "\n## Done\n\n" + head + row("a.md", "done"), dup("a.md", "3, 9")),
        ("./a.md and a.md are one plan", head + row("./a.md") + row("a.md", "done"), dup("a.md", "3, 4")),
        ("a fragment is the same plan", head + row("a.md#status") + row("a.md", "done"), dup("a.md", "3, 4")),
        ("an angle-bracket link is the same plan", head + row("<a.md>") + row("a.md", "done"), dup("a.md", "3, 4")),
        ("a double-quoted title", head + "| d | [P](a.md \"t\") | open | x |\n" + row("a.md", "done"), dup("a.md", "3, 4")),
        ("a single-quoted title", head + "| d | [P](a.md 't') | open | x |\n" + row("a.md", "done"), dup("a.md", "3, 4")),
        ("a parenthesized title", head + "| d | [P](a.md (t)) | open | x |\n" + row("a.md", "done"), dup("a.md", "3, 4")),
        ("a/../a.md is a.md", head + row("specs/../a.md") + row("a.md", "done"), dup("a.md", "3, 4")),
        ("a full reference link", head + "| d | [P][p] | open | x |\n" + row("a.md", "done") + "\n[p]: ./a.md\n", dup("a.md", "3, 4")),
        ("a collapsed reference link", head + "| d | [P][] | open | x |\n" + row("a.md", "done") + "\n[p]: a.md \"t\"\n", dup("a.md", "3, 4")),
        ("a shortcut reference link", head + "| d | [P] | open | x |\n" + row("a.md", "done") + "\n[P]: <a.md>\n", dup("a.md", "3, 4")),
        ("an undefined reference isn't a link", head + "| d | [P] | open | x |\n", ["t.md:3: a row with no plan link in its Plan column"] + none),
        ("an image before the link is skipped", head + "| d | ![i](b.md) [P](a.md) | open | x |\n" + row("a.md", "done"), dup("a.md", "3, 4")),
        ("a code span before the link is skipped", head + "| d | `[c](b.md)` [P](a.md) | open | x |\n" + row("a.md", "done"), dup("a.md", "3, 4")),
        ("an escaped pipe doesn't split the cell", head + "| d | [P \\| Q](a.md) | open | x |\n" + row("a.md", "done"), dup("a.md", "3, 4")),
        ("a row without the outer pipes counts", head + "2026-11-19 | [P](a.md) | open | x\n" + row("a.md", "done"), dup("a.md", "3, 4")),
        ("a link in Evidence isn't the plan", head + "| d | [P](a.md) | open | after [Q](b.md) |\n" + row("b.md"), []),
        ("a Plan cell without a link fails", head + "| d | a.md | open | [Q](b.md) |\n" + row("b.md"), ["t.md:3: a row with no plan link in its Plan column"]),
        ("a table without a Plan column isn't read", "| Status | Meaning |\n|---|---|\n| open | [x](a.md) |\n| done | [x](a.md) |\n\n" + head + row("b.md"), []),
        ("an index with no Plan row fails", "# Plans\n\nNothing here.\n", none),
        ("a fenced example isn't read", head + row("a.md") + "\n```\n" + head + row("a.md") + "```\n", []),
        ("a longer fence isn't closed by a shorter one",
         head + row("a.md") + "\n````\n```\n" + head + row("a.md") + "```\n````\n", []),
        ("a ~~~ fence isn't closed by ```", head + row("a.md") + "\n~~~\n```\n" + row("a.md") + "~~~\n", []),
        ("a link in the prose isn't a row", "See [the plan](a.md).\n\n" + head + row("a.md"), []),
        ("a <<<<<<< line fails", head + "<<<<<<< HEAD\n" + row("a.md"), marker(3)),
        ("a ||||||| line fails (diff3)", head + row("a.md") + "||||||| base\n", marker(4)),
        ("a >>>>>>> line fails", head + row("a.md") + ">>>>>>> origin/main\n", marker(4)),
        ("a whole conflict block fails on each marker", head + "<<<<<<< HEAD\n" + row("a.md") + "=======\n" + row("b.md") + ">>>>>>> origin/main\n",
         marker(3, 5, 7)),
        ("both sides of a conflict block are rows", head + "<<<<<<< HEAD\n" + row("a.md", "done") + "||||||| base\n=======\n" + row("a.md", "proposed") + ">>>>>>> x\n",
         marker(3, 5, 6, 8) + dup("a.md", "4, 7")),
        ("a ======= line alone is a setext underline", "Title\n=======\n\n" + head + row("a.md"), []),
        ("a ======= line after a closed block is a setext underline",
         head + "<<<<<<< HEAD\n>>>>>>> x\n\nTitle\n=======\n\n" + head + row("a.md"), marker(3, 4)),
        ("a marker inside a fence isn't one", head + row("a.md") + "```\n<<<<<<< HEAD\n```\n", []),
    ]
    failed = 0
    for name, text, want in cells_:
        errors, _ = errors_in(text, "t.md")
        ok = errors == want
        print(f"{'ok  ' if ok else 'FAIL'} self-test: {name}" + ("" if ok else f": got {errors}, wanted {want}"))
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
