#!/usr/bin/env python3
"""No tracked shell script under `pipefail` pipes into a reader that stops before its input ends.

`head`, `grep -q`/`-m`/`-l`/`-L` (and egrep, fgrep, rg), `read`, an `awk` that exits outside its
END block, and a `sed` with a `q` command exit once they have what they need. The command writing
into them then gets SIGPIPE, and under `set -o pipefail` the pipeline fails with 141: under `set -e`
the script stops with no message, and in an `if` a match reads as a miss. It happens only when the
writer still has output left, so small inputs hide it. Readers that take the whole input are used
instead: `sed -n '1,Np'` for head, and `awk '/re/ {found = 1} END {exit !found}'` for grep -q.

A command that stops reading a *file* early (`grep -m1 pat file | ...`) is fine: nothing writes into it.

How the check reads a script: lines continued with a trailing `|` or `\\` are joined; each line is
split into words with shell quoting (shlex), so a `|` inside a quoted pattern isn't a pipe; the
command after each pipe is checked, past a `command`/`env`/`stdbuf`/`nice` prefix.

Known gaps (not caught):
- `... | while read ...; do ... break; done` and other loops that leave early (a loop spans lines);
- a reader whose early exit depends on its program beyond these forms (a `python3 -c` or `node -e`
  that stops reading, a `perl` one-liner);
- a line shlex can't split (an unbalanced quote across lines): only that line is skipped;
- scripts that aren't `*.sh`/`*.bash` files, and shell inside `.github/workflows/*.yml` (a
  workflow step's `| head -200` is outside this check; workflows are core paths).

Run: python3 test_pipefail_readers.py (standard library only; needs git and bash).
"""
import pathlib
import re
import shlex
import subprocess
import unittest

REPO = pathlib.Path(__file__).resolve().parent.parent
GREPS = {"grep", "egrep", "fgrep", "rg"}
GREP_EARLY_SHORT = set("qmlL")
GREP_EARLY_LONG = ("--quiet", "--silent", "--max-count", "--files-with-matches", "--files-without-match")
PREFIXES = {"command", "exec", "env", "nice", "stdbuf", "!"}


def logical_lines(text):
    """(first line number, line) with `|`- and backslash-continued lines joined; comment lines dropped."""
    out, buf, first = [], "", None
    for i, raw in enumerate(text.splitlines(), 1):
        if not buf and raw.lstrip().startswith("#"):
            continue
        first = i if not buf else first
        stripped = raw.rstrip()
        if stripped.endswith("\\"):
            buf += stripped[:-1] + " "
            continue
        if stripped.endswith("|") and not stripped.endswith("||"):
            buf += stripped + " "
            continue
        out.append((first, buf + raw))
        buf = ""
    if buf:
        out.append((first, buf))
    return out


def segments(line):
    """The commands after each `|` (not `||`), as word lists; None if the line can't be split."""
    lexer = shlex.shlex(line, posix=True, punctuation_chars="|&;()<>")
    lexer.whitespace_split = True
    lexer.commenters = ""
    try:
        words = list(lexer)
    except ValueError:
        return None
    out, cur, after_pipe = [], [], False
    for w in words:
        if w == "|":
            if after_pipe:
                out.append(cur)
            cur, after_pipe = [], True
        elif re.fullmatch(r"[|&;()<>]+", w):
            if after_pipe:
                out.append(cur)
            cur, after_pipe = [], False
        else:
            cur.append(w)
    if after_pipe:
        out.append(cur)
    return out


def strip_end_blocks(program):
    """An awk program without its END { ... } blocks (braces balanced)."""
    out, i = [], 0
    for m in re.finditer(r"\bEND\s*\{", program):
        if m.start() < i:
            continue
        out.append(program[i:m.start()])
        depth, j = 1, m.end()
        while j < len(program) and depth:
            depth += {"{": 1, "}": -1}.get(program[j], 0)
            j += 1
        i = j
    out.append(program[i:])
    return "".join(out)


def stops_early(words):
    """Why the command `words` can stop before its input ends, or None."""
    while words and (words[0] in PREFIXES or re.fullmatch(r"\w+=.*", words[0])
                     or (words[0].startswith("-") and len(words) > 1)):
        words = words[1:]
    if not words:
        return None
    cmd, args = pathlib.PurePath(words[0]).name, words[1:]
    if cmd in ("head", "read"):
        return cmd
    if cmd in GREPS:
        for a in args:
            if a == "--":
                break
            if a.startswith("--") and a.split("=")[0] in GREP_EARLY_LONG:
                return f"{cmd} {a}"
            if re.fullmatch(r"-[A-Za-z][A-Za-z0-9]*", a) and GREP_EARLY_SHORT & set(re.match(r"[A-Za-z]+", a[1:]).group()):
                return f"{cmd} {a}"
        return None
    if cmd == "awk":
        # The program is the first word that isn't an option or an option's value (-v x=1, -F ,).
        rest, program = list(args), ""
        while rest:
            a = rest.pop(0)
            if a in ("-v", "-F", "-f"):
                rest = rest[1:]
            elif not a.startswith("-"):
                program = a
                break
        if re.search(r"\bexit\b", strip_end_blocks(program)):
            return "awk exit outside END"
        return None
    if cmd == "sed":
        scripts = [a for a in args if not a.startswith("-")][:1]
        scripts += [args[i + 1] for i, a in enumerate(args[:-1]) if a in ("-e", "--expression")]
        for sc in scripts:
            if re.search(r"(^|[;{}\s0-9$/])q(\s*$|[\s;}0-9])", sc):
                return "sed q"
        return None
    return None


def offenders(text):
    if "pipefail" not in text:
        return []
    found = []
    for n, line in logical_lines(text):
        for words in segments(line) or []:
            why = stops_early(words)
            if why:
                found.append((n, f"{why}: {line.strip()}"))
                break
    return found


def bash(script):
    return subprocess.run(["bash", "-c", "set -euo pipefail\n" + script], capture_output=True, text=True)


# ~2 MB on stdout, far more than a pipe holds; the match is on the first line. (Not python: it
# ignores SIGPIPE and exits 1, which would hide the 141.)
PRODUCER = "{ echo CONFIG_X=m; seq 1 300000; }"


class Scripts(unittest.TestCase):
    def test_no_tracked_pipefail_script_pipes_into_an_early_exit_reader(self):
        files = subprocess.run(["git", "ls-files", "*.sh", "*.bash"], cwd=REPO, capture_output=True, text=True, check=True).stdout.split()
        self.assertTrue(files)
        found = [f"{f}:{i}: {line}" for f in files for i, line in offenders((REPO / f).read_text(errors="replace"))]
        self.assertEqual(found, [], "early-exit reader in a pipefail pipeline:\n  " + "\n  ".join(found))

    def test_the_pattern_flags_each_form_and_passes_the_full_readers(self):
        bad = ["find . | sort | head -n 2", "x=$(lsof -t | head -1)", "zcat c.gz | grep -q '^A=m'",
               "cmd | grep -m1 x", "cmd | grep --quiet x", "cmd | awk 'NR==1 {print; exit}'", "cmd | sed '1q'",
               "cmd | grep -l x",
               # joined continuations, other greps, a quoted | before -q, END elsewhere, sed q forms, -L, read
               "find . |\n  sort |\n  head -n 2", "cmd \\\n  | head -1", "cmd | grep \\\n  -q x", "cmd | egrep -q x", "cmd | fgrep -q x",
               "cmd | rg -q x", "cmd | grep -E 'a|b' -q", "cmd | awk 'NR==1 {exit} END {print n}'",
               "cmd | sed '/x/{p;q}'", "cmd | sed 1q", "cmd | sed -n -e '2q'", "cmd | grep -L x", "cmd | read first",
               "cmd | stdbuf -oL head -1", "cmd | /usr/bin/grep -q x", "x=$(cmd | grep --max-count=1 x)"]
        good = ["find . | sort | sed -n '1,2p'", "cmd | awk '/x/ {found = 1} END {exit !found}'",
                "grep -m1 'saved' log | sed 's/.*: //'", "a || head -n 1 f", "cmd | tail -n +2 | wc -l",
                "cmd | grep -oE 'v[0-9]+' | cut -d' ' -f2", "# cmd | head -1",
                "cmd | grep -E 'head|q' | wc -l", "cmd | awk -v re='^x' '$0 ~ re {found = 1} END {exit !found}'",
                "cmd | sed 's/seq/x/'", "a || head -1", "cmd | grep -c x", "echo 'a | head -1'",
                "cmd | awk 'END { if (n) exit 1 }'"]
        for line in bad:
            self.assertTrue(offenders("set -o pipefail\n" + line), line)
        for line in good:
            self.assertFalse(offenders("set -o pipefail\n" + line), line)
        self.assertFalse(offenders("cmd | head -1"), "a script without pipefail isn't affected")


class Idioms(unittest.TestCase):
    """The replacements hold under pipefail where the early readers fail."""

    def test_grep_q_fails_and_the_awk_reader_holds(self):
        self.assertEqual(bash(f"if {PRODUCER} | grep -q '^CONFIG_X=m'; then echo match; else echo miss; fi").stdout, "miss\n")
        for pattern, want in (("^CONFIG_X=m", "match\n"), ("^NOPE", "miss\n")):
            awk = "awk -v re='" + pattern + "' '$0 ~ re {found = 1} END {exit !found}'"
            self.assertEqual(bash(f"if {PRODUCER} | {awk}; then echo match; else echo miss; fi").stdout, want, pattern)

    def test_head_stops_the_script_and_sed_does_not(self):
        done = bash(f'x="$({PRODUCER} | head -n 1)"; echo "got $x"')
        self.assertEqual((done.returncode, done.stdout), (141, ""))
        done = bash(f'x="$({PRODUCER} | sed -n 1p)"; echo "got $x"')
        self.assertEqual((done.returncode, done.stdout), (0, "got CONFIG_X=m\n"))


if __name__ == "__main__":
    unittest.main()
