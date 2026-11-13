#!/usr/bin/env python3
"""Find Python text I/O that relies on the locale's encoding.

On a host whose default encoding isn't UTF-8 (Windows with cp950, for example), a text read or
write without `encoding=` fails or corrupts a UTF-8 file. This lint flags, in the tracked Python
files of deep-research/ and scripts/:
  - `x.read_text()` / `x.write_text(...)` without `encoding=`;
  - `open(...)`, `x.open(...)`, `io.open(...)` in text mode (no mode, or a mode without "b")
    without `encoding=`; `gzip.open`, `bz2.open` and `lzma.open` alike ("rt"/"wt" are text);
  - `subprocess.run/check_output/Popen(..., text=True)` (or `universal_newlines=True`) without
    `encoding=`.
A mode the lint can't read (a variable) is flagged too: pass `encoding=` or mark the line with
`# text-encoding: ok` and say why.

Usage:
  scripts/lint-text-encoding.py            lint the tracked files, exit 1 on a finding
  scripts/lint-text-encoding.py --fix      add encoding="utf-8" where the call can take it
  scripts/lint-text-encoding.py --self-test
"""
import ast
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PATHSPECS = ["deep-research/*.py", "scripts/*.py"]
SUBPROCESS_CALLS = {"run", "check_output", "Popen", "call", "check_call"}
WAIVER = "# text-encoding: ok"


def _keywords(call):
    return {k.arg for k in call.keywords if k.arg}


def _kw(call, name):
    for k in call.keywords:
        if k.arg == name:
            return k.value
    return None


def _mode(call, positional_index):
    """The call's mode as a string, None when absent, or ... when it can't be read."""
    node = _kw(call, "mode")
    if node is None and len(call.args) > positional_index:
        node = call.args[positional_index]
    if node is None:
        return None
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    return ...


def findings(source):
    """(line, col, end_line, end_col, message, fixable) for each finding in `source`."""
    tree = ast.parse(source)
    lines = source.splitlines()
    out = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call) or "encoding" in _keywords(node):
            continue
        func = node.func
        name = func.attr if isinstance(func, ast.Attribute) else func.id if isinstance(func, ast.Name) else None
        message = None
        fixable = True
        if name in ("read_text", "write_text") and isinstance(func, ast.Attribute):
            message = f"{name}() without encoding="
        elif name == "open":
            # open(file, mode) as a builtin or io.open; path.open(mode) as a method.
            is_method = isinstance(func, ast.Attribute) and not (
                isinstance(func.value, ast.Name) and func.value.id in ("io", "codecs", "gzip", "bz2", "lzma")
            )
            mode = _mode(node, 0 if is_method else 1)
            if mode is ...:
                message, fixable = "open() with a mode the lint can't read, without encoding=", False
            elif mode is None and isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name) \
                    and func.value.id in ("gzip", "bz2", "lzma"):
                pass  # their default mode is binary
            elif mode is None or "b" not in mode:
                message = "open() in text mode without encoding="
        elif name in SUBPROCESS_CALLS and isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name) \
                and func.value.id == "subprocess":
            for flag in ("text", "universal_newlines"):
                value = _kw(node, flag)
                if isinstance(value, ast.Constant) and value.value is True:
                    message = f"subprocess.{name}({flag}=True) without encoding="
        if message is None:
            continue
        if WAIVER in lines[node.lineno - 1]:
            continue
        out.append((node.lineno, node.col_offset, node.end_lineno, node.end_col_offset, message, fixable))
    return out


def fix(source):
    """Adds encoding="utf-8" to every fixable finding; returns the new source."""
    lines = source.splitlines(keepends=True)
    offsets = [0]
    for line in lines:
        offsets.append(offsets[-1] + len(line))
    edits = []
    for _, _, end_line, end_col, _, fixable in findings(source):
        if not fixable:
            continue
        # ast columns are UTF-8 byte offsets; the source is indexed by character.
        line_text = lines[end_line - 1]
        end_char = len(line_text.encode("utf-8")[:end_col].decode("utf-8"))
        close = offsets[end_line - 1] + end_char - 1  # the call's closing parenthesis
        assert source[close] == ")", (end_line, end_col)
        before = source[:close].rstrip()
        if before.endswith("("):
            insert = 'encoding="utf-8"'
        elif before.endswith(","):
            insert = ' encoding="utf-8"' if source[close - 1] != "\n" else 'encoding="utf-8",\n'
        else:
            insert = ', encoding="utf-8"'
        if before.endswith(",") and source[close - 1] == "\n":
            # A call split over lines with a trailing comma: add a line in the same style.
            indent = source[offsets[end_line - 1]:close]
            insert = indent + "    " + 'encoding="utf-8",\n'
            edits.append((close - len(indent), insert))
            continue
        edits.append((len(before), insert))
    for position, insert in sorted(edits, reverse=True):
        source = source[:position] + insert + source[position:]
    return source


def tracked():
    out = subprocess.run(["git", "ls-files", "-z", *PATHSPECS], cwd=ROOT, check=True,
                         capture_output=True).stdout.decode("utf-8")
    others = subprocess.run(["git", "ls-files", "-z", "--others", "--exclude-standard", *PATHSPECS],
                            cwd=ROOT, check=True, capture_output=True).stdout.decode("utf-8")
    return sorted({p for p in (out + others).split("\0") if p})


def self_test():
    cases = [
        ('Path("a").read_text()\n', 1, 'Path("a").read_text(encoding="utf-8")\n'),
        ('p.write_text(s)\n', 1, 'p.write_text(s, encoding="utf-8")\n'),
        ('open(p)\n', 1, 'open(p, encoding="utf-8")\n'),
        ('open(p, "w")\n', 1, 'open(p, "w", encoding="utf-8")\n'),
        ('open(p, "rb")\n', 0, None),
        ('p.open("wb")\n', 0, None),
        ('p.open()\n', 1, 'p.open(encoding="utf-8")\n'),
        ('p.open("a")\n', 1, 'p.open("a", encoding="utf-8")\n'),
        ('open(p, mode)\n', 1, None),
        ('open(p, mode)  # text-encoding: ok (binary by contract)\n', 0, None),
        ('open(p, encoding="utf-8")\n', 0, None),
        ('subprocess.run(c, text=True)\n', 1, 'subprocess.run(c, text=True, encoding="utf-8")\n'),
        ('subprocess.run(c, capture_output=True)\n', 0, None),
        ('open(\n    p,\n    "w",\n)\n', 1, 'open(\n    p,\n    "w",\n    encoding="utf-8",\n)\n'),
        ('x.read_text(\n)\n', 1, None),
        ('gzip.open(p, "rt")\n', 1, 'gzip.open(p, "rt", encoding="utf-8")\n'),
        ('gzip.open(p)\n', 0, None),
        ('print("é"); p.read_text()\n', 1, 'print("é"); p.read_text(encoding="utf-8")\n'),
    ]
    failed = 0
    for source, want, fixed in cases:
        got = findings(source)
        if len(got) != want:
            print(f"FAIL findings {source!r}: {len(got)} != {want}")
            failed += 1
            continue
        if fixed is not None:
            result = fix(source)
            if result != fixed or findings(result):
                print(f"FAIL fix {source!r}: {result!r}")
                failed += 1
        elif want and all(f[5] for f in got):
            result = fix(source)
            if findings(result):
                print(f"FAIL fix {source!r} left a finding: {result!r}")
                failed += 1
    print(f"lint-text-encoding self-test: {len(cases) - failed}/{len(cases)} passed")
    return 1 if failed else 0


def main(argv):
    if argv[1:] == ["--self-test"]:
        return self_test()
    do_fix = argv[1:] == ["--fix"]
    total = 0
    for rel in tracked():
        path = ROOT / rel
        source = path.read_text(encoding="utf-8")
        if do_fix:
            fixed = fix(source)
            if fixed != source:
                path.write_text(fixed, encoding="utf-8")
                source = fixed
        for line, col, _, _, message, _ in findings(source):
            print(f"{rel}:{line}:{col + 1}: {message}")
            total += 1
    if total:
        print(f"lint-text-encoding: {total} finding(s); pass encoding=\"utf-8\" (or mark the line "
              f"with '{WAIVER}' and say why)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
